// FloeApp — Native workspace canvas.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import AVKit
import PencilKit
import SceneKit
import UniformTypeIdentifiers
import WebKit
import CryptoKit
import FloeCore
import FloeImages
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
                Task { @MainActor in
                    do {
                        let project = try WorkspaceCanvasRegistry.project(canvasID: summary.id)
                        try await CanvasLifecycleService.deleteProject(
                            project: project,
                            environment: environment
                        )
                        listRevision += 1
                    } catch {
                        environment.workspaceCenter.actionError = error.localizedDescription
                    }
                }
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

private enum CanvasNodeCreationSection: String, CaseIterable, Identifiable {
    case basic, media, creation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: "基础节点"
        case .media: "媒体与文件"
        case .creation: "创作节点"
        }
    }
}

/// One source of truth for every node-creation surface: toolbar, blank-canvas
/// double click, pointer context menu, Pencil palette and keyboard commands.
private enum CanvasNodeCreationKind: String, CaseIterable, Identifiable {
    case text, stickyNote, card, shape, group, image, video, audio, file
    case imageGeneration, videoGeneration, markdown, svg, html, panorama3D, scene3D

    var id: String { rawValue }
    var section: CanvasNodeCreationSection {
        switch self {
        case .text, .stickyNote, .card, .shape, .group: .basic
        case .image, .video, .audio, .file: .media
        case .imageGeneration, .videoGeneration, .markdown, .svg, .html, .panorama3D, .scene3D: .creation
        }
    }
    var title: String {
        switch self {
        case .text: "文本"
        case .stickyNote: "便签"
        case .card: "基础卡片"
        case .shape: "形状"
        case .group: "分组"
        case .image: "图片卡片"
        case .video: "视频卡片"
        case .audio: "音频卡片"
        case .file: "文件卡片"
        case .imageGeneration: "图片生成"
        case .videoGeneration: "视频生成"
        case .markdown: "Markdown"
        case .svg: "SVG"
        case .html: "HTML"
        case .panorama3D: "3D 全景"
        case .scene3D: "3D 场景"
        }
    }
    var icon: String {
        switch self {
        case .text: "textformat"
        case .stickyNote: "note.text"
        case .card: "rectangle.and.text.magnifyingglass"
        case .shape: "square.on.circle"
        case .group: "square.3.layers.3d"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .file: "doc"
        case .imageGeneration: "photo.badge.plus"
        case .videoGeneration: "video.badge.plus"
        case .markdown: "text.document"
        case .svg: "scribble.variable"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .panorama3D: "pano"
        case .scene3D: "cube.transparent"
        }
    }
}

private enum CanvasContextTarget: Equatable {
    case canvas(CGPoint)
    case nodes(Set<UUID>)
    case connection(UUID)
    case ink(Set<UUID>)
}

private enum CanvasContextAction: String, CaseIterable, Identifiable {
    case create, paste, importAsset, fitCanvas, edit, askAI, duplicate, connect
    case group, ungroup, lock, unlock, bringToFront, sendToBack, export, delete
    case reverseConnection, interpretInk, inkToCard, inkToText, inkToShape
    var id: String { rawValue }
}

private struct CanvasNodeCreationMenu: View {
    let onCreate: (CanvasNodeCreationKind) -> Void

    var body: some View {
        ForEach(CanvasNodeCreationSection.allCases) { section in
            Section(section.title) {
                ForEach(CanvasNodeCreationKind.allCases.filter { $0.section == section }) { kind in
                    Button(kind.title, systemImage: kind.icon) { onCreate(kind) }
                }
            }
        }
    }
}

private struct CanvasNodeCreationPalette: View {
    let onCreate: (CanvasNodeCreationKind) -> Void
    let onDismiss: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("新建节点").font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(CanvasNodeCreationKind.allCases) { kind in
                        Button {
                            onCreate(kind)
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: kind.icon).font(.title3)
                                Text(kind.title).font(.caption).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("canvas.node.create.\(kind.rawValue)")
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
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
        project.agentConversationID = nil
        project.assistantSessions = []
        project.selectedAssistantSessionID = nil
        project.agentConversationIDsByDocument = [:]
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

    static func project(canvasID: UUID) throws -> CanvasProject {
        try decodeProject(at: projectURL(canvasID: canvasID, createDirectory: false))
    }

    static func packageData(canvasID: UUID) throws -> Data {
        try Data(contentsOf: projectURL(canvasID: canvasID, createDirectory: false))
    }

    @discardableResult
    static func importPackage(from source: URL) throws -> UUID {
        var project = try decodeProject(at: source)
        guard !project.documents.isEmpty,
              (1...CanvasProject.currentSchemaVersion).contains(project.schemaVersion) else {
            throw FloeError.validationFailed("这不是受支持的 Floe 画布包。")
        }
        let id = UUID()
        project.id = id
        project.workspaceID = nil
        project.agentConversationID = nil
        project.assistantSessions = []
        project.selectedAssistantSessionID = nil
        project.agentConversationIDsByDocument = [:]
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
private enum CanvasLifecycleService {
    static func prepareDocumentDeletion(
        project: FloeCanvasProject,
        documentID: UUID,
        environment: AppEnvironment
    ) async throws {
        if let conversationID = project.agentConversationIDsByDocument[documentID] {
            try await environment.conversationCenter.deleteConversation(id: conversationID)
        }
        try await cancelAndDeleteMediaJobs(
            canvasID: project.id,
            documentID: documentID,
            environment: environment
        )
    }

    static func deleteProject(
        project: FloeCanvasProject,
        environment: AppEnvironment
    ) async throws {
        var conversationIDs = Set(project.agentConversationIDsByDocument.values)
        conversationIDs.formUnion(project.assistantSessions.map(\.conversationID))
        if let legacyConversationID = project.agentConversationID {
            conversationIDs.insert(legacyConversationID)
        }
        for conversationID in conversationIDs {
            if try await environment.conversationStore.conversation(id: conversationID) != nil {
                try await environment.conversationCenter.deleteConversation(id: conversationID)
            }
        }
        try await cancelAndDeleteMediaJobs(
            canvasID: project.id,
            documentID: nil,
            environment: environment
        )
        let operation = CanvasSyncOperation(
            canvasID: project.id,
            entityKind: .tombstone,
            entityID: project.id,
            mutation: .delete,
            revision: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try await environment.canvasSyncOperationStore.enqueue(operation)
        try WorkspaceCanvasRegistry.delete(canvasID: project.id)
        for assetID in project.documents.flatMap(\.nodes).compactMap(\.asset?.id) {
            try? await environment.creativeAssetStore.adjustReference(assetID: assetID, by: -1)
        }
    }

    private static func cancelAndDeleteMediaJobs(
        canvasID: UUID,
        documentID: UUID?,
        environment: AppEnvironment
    ) async throws {
        let store = MediaGenerationJobStore(database: environment.database)
        let jobs = try await store.jobs(canvasID: canvasID).filter {
            documentID == nil || $0.documentID == documentID
        }
        for job in jobs where !job.state.isTerminal {
            if job.mediaKind == .video, job.providerTaskID != nil {
                // Project deletion must stay available offline. Ask the remote
                // provider to cancel, then always close the durable local job.
                try? await environment.mediaGenerationService.cancelVideo(jobID: job.id)
            }
            if let current = try await store.job(id: job.id), !current.state.isTerminal {
                _ = try await store.transition(id: job.id, to: .cancelled) {
                    $0.nextPollAt = nil
                }
            }
        }
        try await store.deleteJobs(canvasID: canvasID, documentID: documentID)
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
                    // Canonicalize legacy schema without manufacturing an
                    // edit revision merely because the document was opened.
                    persist(incrementRevision: false)
                } else {
                    let backup = try Self.preserveReadOnlyBackup(of: fileURL)
                    project = fallback
                    persist(incrementRevision: false)
                    saveError = "原画布无法迁移，已保留只读备份：\(backup.lastPathComponent)"
                }
            } else {
                project = fallback
                persist(incrementRevision: false)
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
        let currentRevision = project.revision
        redoStack.append(project)
        project = previous
        project.revision = currentRevision
        project.updatedAt = Date()
        persist()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let currentRevision = project.revision
        undoStack.append(project)
        project = next
        project.revision = currentRevision
        project.updatedAt = Date()
        persist()
    }

    func reloadExternalChange() {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let incoming = try CanvasProjectCodec.decode(
                Data(contentsOf: fileURL), fallbackID: project.id, decoder: decoder
            )
            guard incoming.id == project.id, incoming.revision > project.revision else { return }
            recordHistory()
            project = incoming
            saveError = nil
        } catch {
            saveError = "重新载入画布失败：\(error.localizedDescription)"
        }
    }

    func updateViewport(center: CanvasPoint, scale: Double) {
        project.viewports[project.selectedDocumentID] = CanvasViewportState(
            center: center, scale: scale
        )
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
        project.agentConversationID = project.agentConversationIDsByDocument[id]
        project.updatedAt = Date()
        persist()
    }

    func addDocument() {
        let document = FloeCanvasDocument(name: "画布 \(project.documents.count + 1)")
        project.documents.append(document)
        project.selectedDocumentID = document.id
        project.agentConversationID = nil
        project.updatedAt = Date()
        persist()
    }

    func deleteDocument(_ id: UUID) {
        guard project.documents.count > 1 else { return }
        let assetIDs = project.documents.first(where: { $0.id == id })?.nodes.compactMap(\.asset?.id) ?? []
        project.documents.removeAll { $0.id == id }
        project.viewports[id] = nil
        project.agentConversationIDsByDocument[id] = nil
        if project.selectedDocumentID == id {
            project.selectedDocumentID = project.documents[0].id
        }
        project.agentConversationID = project.agentConversationIDsByDocument[project.selectedDocumentID]
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

    /// Creates a real sticky-note node. Keeping it distinct from a structured
    /// card lets every creation entry point expose both concepts honestly.
    @discardableResult
    func addStickyNote(at point: CGPoint, text: String = "新建便签") -> UUID {
        let id = addPlaceholder(kind: .stickyNote, at: point)
        if text != "新建便签" { updateNode(id, text: text) }
        return id
    }

    @discardableResult
    func addCard(at point: CGPoint, text: String = "新建卡片") -> UUID {
        let id = addPlaceholder(kind: .card, at: point)
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
        let id = UUID()
        _ = applyCommand([
            CanvasPatchOperation(
                kind: .create, nodeID: id, nodeKind: kind,
                position: CanvasPoint(point)
            )
        ])
        return id
    }

    func attachAsset(
        _ asset: CanvasAssetReference,
        kind: CanvasNodeKind,
        to nodeID: UUID
    ) {
        guard [.image, .video, .audio, .file].contains(kind) else { return }
        let previousAssetID = selectedDocument?.nodes.first(where: { $0.id == nodeID })?.asset?.id
        let displayName = asset.localRelativePath?.split(separator: "/").last.map(String.init)
        guard applyCommand([
            CanvasPatchOperation(
                kind: .update, nodeID: nodeID, nodeKind: kind,
                text: displayName, asset: asset
            )
        ]) != nil else { return }
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
        guard applyCommand([
            CanvasPatchOperation(
                kind: .create, nodeID: id, nodeKind: kind,
                text: asset.localRelativePath?.split(separator: "/").last.map(String.init) ?? "素材",
                position: CanvasPoint(point),
                size: .init(width: 320, height: kind == .video ? 220 : 260),
                asset: asset
            )
        ]) != nil else { return id }
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
    func prepareGenerationGraph(
        _ request: CanvasGenerationGraphRequest
    ) -> CanvasGenerationGraphPlan? {
        guard let document = selectedDocument else { return nil }
        do {
            let plan = try CanvasGenerationGraphPlanner.plan(
                request: request, document: document
            )
            guard applyCommand(plan.operations, documentID: document.id) != nil else {
                return nil
            }
            return plan
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func addScene3D(at point: CGPoint) -> UUID {
        addPlaceholder(kind: .scene3D, at: point)
    }

    @discardableResult
    func addBuiltinNode(pluginID: String, at point: CGPoint) -> UUID {
        let kind: CanvasNodeKind = pluginID == "panorama3D" ? .image : .card
        let id = addPlaceholder(kind: kind, at: point)
        let defaults: [String: String] = [
            "markdown": "# Markdown\n\n双击编辑内容。",
            "svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 180\"><rect width=\"320\" height=\"180\" rx=\"24\" fill=\"#5B8DEF\"/><text x=\"160\" y=\"100\" text-anchor=\"middle\" fill=\"white\" font-size=\"28\">SVG</text></svg>",
            "html": "<h2>HTML 节点</h2><p>双击编辑安全的静态 HTML。</p>",
            "panorama3D": "3D 全景"
        ]
        updateNode(id, text: defaults[pluginID] ?? pluginID)
        updateNodeMetadata(id, values: ["builtinPlugin": pluginID])
        return id
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
            document.nodes[index].metadata["generationState"] = "submitted"
        }
    }

    func setBackgroundStyle(_ style: CanvasBackgroundStyle) {
        mutateSelectedDocument { document in
            document.backgroundStyle = style
        }
    }

    func updateNodeMetadata(_ nodeID: UUID, values: [String: String?]) {
        mutateSelectedDocument { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            for (key, value) in values {
                if let value { document.nodes[index].metadata[key] = value }
                else { document.nodes[index].metadata.removeValue(forKey: key) }
            }
        }
    }

    /// Returns the explicit selection plus every recursively connected
    /// upstream node. Generation and assistant flows share this resolver so
    /// visible connections have one consistent semantic meaning.
    func generationSourceNodes(for selectedIDs: Set<UUID>) -> [FloeCanvasNode] {
        guard let document = selectedDocument else { return [] }
        var included = selectedIDs
        var frontier = selectedIDs
        while !frontier.isEmpty {
            let parents = Set(document.connections.compactMap { connection in
                frontier.contains(connection.destinationNodeID) ? connection.sourceNodeID : nil
            }).subtracting(included)
            included.formUnion(parents)
            frontier = parents
        }
        return document.nodes.filter { included.contains($0.id) }.sorted {
            if $0.x == $1.x { return $0.y < $1.y }
            return $0.x < $1.x
        }
    }

    func markGeneration(
        nodeID: UUID,
        kind: MediaKind,
        prompt: String,
        modelID: UUID?,
        aspectRatio: String,
        quality: String?,
        count: Int,
        sourceNodeIDs: [UUID],
        state: String,
        error: String? = nil
    ) {
        updateNodeMetadata(nodeID, values: [
            "generationKind": kind.rawValue,
            "generationPrompt": prompt,
            "generationModelID": modelID?.uuidString,
            "generationAspectRatio": aspectRatio,
            "generationQuality": quality,
            "generationCount": String(count),
            "generationSourceNodeIDs": sourceNodeIDs.map(\.uuidString).joined(separator: ","),
            "generationState": state,
            "generationError": error
        ])
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
        guard selectedDocument?.connections.contains(where: {
            $0.sourceNodeID == source && $0.destinationNodeID == destination && $0.kind == kind
                && $0.sourcePort == sourcePort && $0.destinationPort == destinationPort
        }) != true else { return }
        _ = applyCommand([
            CanvasPatchOperation(
                kind: .connect, sourceNodeID: source, destinationNodeID: destination,
                connectionKind: kind,
                sourcePort: sourcePort, destinationPort: destinationPort
            )
        ])
    }

    func deleteConnection(_ id: UUID) {
        _ = applyCommand([CanvasPatchOperation(kind: .disconnect, connectionID: id)])
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
        guard applyCommand([CanvasPatchOperation(kind: .delete, nodeIDs: Array(ids))]) != nil else {
            return
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
        _ = applyCommand(ids.map {
            CanvasPatchOperation(kind: .update, nodeID: $0, isLocked: locked)
        })
    }

    func group(_ ids: Set<UUID>) {
        guard ids.count > 1 else { return }
        let groupID = UUID()
        _ = applyCommand([
            CanvasPatchOperation(kind: .group, nodeID: groupID, nodeIDs: Array(ids))
        ])
    }

    func setSyncEnabled(_ enabled: Bool) {
        var sync = project.sync
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

    @discardableResult
    func applyAgentResult(text: String, to sourceNodeID: UUID, runID: UUID) -> UUID? {
        guard let source = selectedDocument?.nodes.first(where: { $0.id == sourceNodeID }) else {
            return nil
        }
        if source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutateSelectedDocument { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == sourceNodeID }) else { return }
                document.nodes[index].text = text
                document.nodes[index].createdByRunID = runID
            }
            return sourceNodeID
        }
        var resultID: UUID?
        mutateSelectedDocument { document in
            let id = UUID()
            document.nodes.append(FloeCanvasNode(
                id: id, text: text,
                x: source.x + source.width / 2 + 250,
                y: source.y, width: max(300, source.width), height: max(180, source.height),
                createdByRunID: runID,
                kind: .card, zIndex: (document.nodes.map(\.zIndex).max() ?? 0) + 1,
                metadata: ["generatedFromNodeID": sourceNodeID.uuidString]
            ))
            document.connections.append(CanvasConnection(
                sourceNodeID: sourceNodeID, destinationNodeID: id,
                kind: .generatedFrom, label: "AI 结果",
                sourcePort: .trailing, destinationPort: .leading
            ))
            resultID = id
        }
        return resultID
    }

    func agentConversationID(for documentID: UUID) -> UUID? {
        project.agentConversationIDsByDocument[documentID]
    }

    func setAgentConversationID(_ id: UUID, for documentID: UUID) {
        guard project.documents.contains(where: { $0.id == documentID }) else { return }
        project.agentConversationIDsByDocument[documentID] = id
        project.agentConversationID = id
        project.schemaVersion = CanvasProject.currentSchemaVersion
        project.updatedAt = Date()
        persist()
    }

    /// Compatibility wrapper for callers that have not yet adopted
    /// document-scoped assistant ownership.
    func updateNode(
        _ id: UUID,
        text: String? = nil,
        position: CGPoint? = nil,
        persistAfter: Bool = true
    ) {
        if persistAfter {
            _ = applyCommand([
                CanvasPatchOperation(
                    kind: .update, nodeID: id, text: text,
                    position: position.map(CanvasPoint.init)
                )
            ])
            return
        }
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
        if persistAfter {
            let commandSize: CanvasSize?
            if width != nil || height != nil {
                let current = selectedDocument?.nodes.first(where: { $0.id == id })?.size
                commandSize = CanvasSize(
                    width: width ?? current?.width ?? 300,
                    height: height ?? current?.height ?? 180
                )
            } else {
                commandSize = nil
            }
            _ = applyCommand([
                CanvasPatchOperation(
                    kind: .update, nodeID: id,
                    size: commandSize,
                    rotation: rotation
                )
            ])
            return
        }
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
        guard applyCommand([CanvasPatchOperation(kind: .delete, nodeID: id)]) != nil else {
            return
        }
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
        _ = applyCommand([CanvasPatchOperation(kind: .ungroup, nodeIDs: Array(ids))])
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

    @discardableResult
    private func applyCommand(
        _ operations: [CanvasPatchOperation],
        documentID: UUID? = nil
    ) -> CanvasOperationResult? {
        let targetDocumentID = documentID ?? project.selectedDocumentID
        do {
            let patch = CanvasPatch(
                canvasID: project.id,
                documentID: targetDocumentID,
                expectedRevision: project.revision,
                operations: operations
            )
            let (updated, result) = try CanvasCommandService.applying(patch, to: project)
            recordHistory()
            project = updated
            persist(incrementRevision: false)
            return result
        } catch {
            saveError = error.localizedDescription
            return nil
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

    private func persist(incrementRevision: Bool = true) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if incrementRevision { project.revision += 1 }
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

private struct CanvasImageEditorPresentation: Identifiable {
    let id: UUID
}

private struct CanvasDeletionRequest: Identifiable {
    let id: UUID
    let name: String
    let deletesProject: Bool
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
    @AppStorage("creative.canvas.appearance") private var canvasAppearance = "system"
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
    @State private var showsPromptLibrary = false
    @State private var materialKindFilter: Set<CanvasNodeKind>?
    @State private var materialTargetNodeID: UUID?
    @State private var connectionStartID: UUID?
    @State private var connectionStartPort: CanvasConnectionPort?
    @State private var selectedConnectionID: UUID?
    @State private var pendingAgentRequest: CanvasAgentRequest?
    @State private var enteredGroupID: UUID?
    @State private var showsGeneration = false
    @State private var showsInspector = false
    @State private var imageEditorPresentation: CanvasImageEditorPresentation?
    @State private var showsMediaJobs = false
    @State private var directorPresentation: Canvas3DDirectorPresentation?
    @State private var canvasJobs: [MediaGenerationJob] = []
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var exportDocument: CanvasBinaryDocument?
    @State private var exportContentType: UTType = .floeCanvasPackage
    @State private var exportFilename = "Floe 画布"
    @State private var nodeCreationPoint: CGPoint?
    @State private var lastCanvasPointerPoint: CGPoint?
    @State private var pencilContextPoint: CGPoint?
    @State private var showsMiniMap = true
    @State private var pendingCanvasDeletion: CanvasDeletionRequest?
    @State private var isDeletingCanvas = false

    private static let nodePasteboardType = "org.floeagent.canvas.nodes"

    private enum CanvasMode: String, CaseIterable, Identifiable {
        case select, hand, pencil, eraser, connector
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: "选择"
            case .hand: "移动画布"
            case .pencil: "画笔"
            case .eraser: "橡皮"
            case .connector: "连接线"
            }
        }
        var icon: String {
            switch self {
            case .select: "cursorarrow"
            case .hand: "hand.draw"
            case .pencil: "pencil.tip"
            case .eraser: "eraser"
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
        .preferredColorScheme(
            canvasAppearance == "light" ? .light
                : canvasAppearance == "dark" ? .dark : nil
        )
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
        .alert(item: $pendingCanvasDeletion) { request in
            Alert(
                title: Text(request.deletesProject ? "删除整个画布项目？" : "删除画布？"),
                message: Text(request.deletesProject
                    ? "“\(request.name)”是最后一张画布。继续将删除整个画布项目、关联的画布助手会话和未完成媒体任务。绑定的工作区不会被删除。"
                    : "将删除“\(request.name)”及其画布助手会话。此操作无法撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    Task { await performDeletion(request) }
                },
                secondaryButton: .cancel()
            )
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
        .sheet(isPresented: $showsPromptLibrary) {
            NavigationStack {
                CanvasPromptLibraryView { record in
                    selectedNodeIDs = [store.addNote(
                        at: canvasPoint(CGPoint(x: 520, y: 380)),
                        text: record.prompt
                    )]
                    showsPromptLibrary = false
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
        .sheet(item: $imageEditorPresentation) { presentation in
            if let node = store.selectedDocument?.nodes.first(where: {
                $0.id == presentation.id && $0.kind == .image
            }) {
                CanvasLocalImageEditor(store: store, node: node) { resultID in
                    selectedNodeIDs = [resultID]
                    imageEditorPresentation = nil
                }
                .environmentObject(environment)
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
            restoreViewport()
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
        .onReceive(NotificationCenter.default.publisher(for: .floeCanvasProjectDidChange)) { note in
            guard note.userInfo?["canvasID"] as? UUID == store.project.id else { return }
            store.reloadExternalChange()
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
        .onChange(of: store.project.selectedDocumentID) { _, _ in
            restoreViewport()
            selectedNodeIDs.removeAll()
            selectedConnectionID = nil
            editingNodeID = nil
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
                documentSidebarRow(document)
            }
        }
        .navigationTitle("画布")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.addDocument() } label: {
                    Label("新建画布", systemImage: "plus")
                }
                .disabled(isDeletingCanvas)
            }
        }
    }

    private func documentSidebarRow(_ document: FloeCanvasDocument) -> some View {
        HStack(spacing: 4) {
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
            Menu {
                Button("删除画布", systemImage: "trash", role: .destructive) {
                    requestDeletion(document)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(document.name)操作")
        }
        .disabled(isDeletingCanvas)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) { requestDeletion(document) }
        }
        .contextMenu {
            Button("删除画布", systemImage: "trash", role: .destructive) {
                requestDeletion(document)
            }
        }
    }

    private func requestDeletion(_ document: FloeCanvasDocument) {
        guard !isDeletingCanvas else { return }
        pendingCanvasDeletion = CanvasDeletionRequest(
            id: document.id,
            name: document.name,
            deletesProject: store.project.documents.count == 1
        )
    }

    @MainActor
    private func performDeletion(_ request: CanvasDeletionRequest) async {
        guard !isDeletingCanvas,
              store.project.documents.contains(where: { $0.id == request.id }) else { return }
        isDeletingCanvas = true
        defer { isDeletingCanvas = false }
        do {
            if request.deletesProject {
                try await CanvasLifecycleService.deleteProject(
                    project: store.project,
                    environment: environment
                )
                dismiss()
            } else {
                try await CanvasLifecycleService.prepareDocumentDeletion(
                    project: store.project,
                    documentID: request.id,
                    environment: environment
                )
                store.deleteDocument(request.id)
            }
        } catch is CancellationError {
            return
        } catch {
            store.saveError = "删除失败：\(error.localizedDescription)"
        }
    }

    private var canvasDetail: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                if let document = store.selectedDocument {
                    if canvasPreferences.showGrid {
                        canvasBackground(
                            style: document.backgroundStyle ?? .grid,
                            size: geometry.size
                        )
                    }
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
                    groupLayer(document)
                        .allowsHitTesting(false)
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
                if let nodeCreationPoint {
                    CanvasNodeCreationPalette { kind in
                        createNode(kind, at: canvasPoint(nodeCreationPoint))
                        withAnimation(.snappy) { self.nodeCreationPoint = nil }
                    } onDismiss: {
                        withAnimation(.snappy) { self.nodeCreationPoint = nil }
                    }
                    .frame(width: min(360, geometry.size.width - 28))
                    .position(
                        x: min(max(190, nodeCreationPoint.x), geometry.size.width - 190),
                        y: min(max(170, nodeCreationPoint.y), geometry.size.height - 170)
                    )
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .zIndex(40)
                }
                if let pencilContextPoint {
                    pencilContextMenu(size: geometry.size)
                        .position(
                            x: min(max(150, pencilContextPoint.x), geometry.size.width - 150),
                            y: min(max(42, pencilContextPoint.y), geometry.size.height - 42)
                        )
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .zIndex(45)
                }
                if showsAgent {
                    let compactAgentPanel = geometry.size.width < 620
                    let agentPanelWidth = isAgentCollapsed
                        ? min(232, geometry.size.width - 16)
                        : (compactAgentPanel
                            ? max(280, geometry.size.width - 16)
                            : min(392, max(320, geometry.size.width - 24)))
                    let agentPanelHeight = isAgentCollapsed
                        ? 56
                        : min(compactAgentPanel ? 520 : 640, max(300, geometry.size.height - 24))
                    CanvasAgentFloatingPanel(
                        store: store,
                        workspace: workspace,
                        contextSnapshot: canvasAgentContext,
                        selectedNodeIDs: selectedNodeIDs,
                        pendingRequest: $pendingAgentRequest,
                        availableSize: geometry.size,
                        offset: $agentPanelOffset,
                        isCollapsed: $isAgentCollapsed,
                        onClose: {
                            withAnimation(.snappy) { showsAgent = false }
                        }
                    )
                    .environmentObject(environment)
                    .frame(width: agentPanelWidth, height: agentPanelHeight)
                    .position(
                        x: compactAgentPanel
                            ? geometry.size.width / 2
                            : geometry.size.width - agentPanelWidth / 2 - 12,
                        y: compactAgentPanel
                            ? geometry.size.height - agentPanelHeight / 2 - 12
                            : agentPanelHeight / 2 + 12
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
                CanvasPencilInteractionBridge(onTap: {
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
                }, onSqueeze: { location in
                    withAnimation(.snappy) {
                        pencilContextPoint = location ?? CGPoint(
                            x: geometry.size.width / 2,
                            y: geometry.size.height / 2
                        )
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .overlay(alignment: .bottomLeading) {
                if showsMiniMap, let document = store.selectedDocument {
                    CanvasMiniMap(
                        document: document,
                        viewportCenter: CanvasPoint(
                            x: (geometry.size.width / 2 - pan.width) / scale,
                            y: (geometry.size.height / 2 - pan.height) / scale
                        ),
                        viewportSize: CanvasSize(
                            width: geometry.size.width / scale,
                            height: geometry.size.height / scale
                        )
                    ) { center, finished in
                        pan = CGSize(
                            width: geometry.size.width / 2 - center.x * scale,
                            height: geometry.size.height / 2 - center.y * scale
                        )
                        panStart = pan
                        if finished { persistViewport() }
                    }
                    .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    selectionToolbar
                    modeControls(size: geometry.size)
                }
            }
            .navigationTitle(store.selectedDocument?.name ?? "画布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Menu {
                            CanvasNodeCreationMenu { kind in
                                createNode(kind, at: canvasPoint(CGPoint(x: 520, y: 380)))
                            }
                            Divider()
                            Button("从素材库添加…", systemImage: "photo.on.rectangle.angled") {
                                materialTargetNodeID = nil
                                materialKindFilter = [.image, .video, .audio, .file]
                                showsMaterials = true
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
                            showsPromptLibrary = true
                        } label: {
                            Label("提示词库", systemImage: "books.vertical")
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
                            Menu("画布背景") {
                                ForEach(CanvasBackgroundStyle.allCases, id: \.self) { style in
                                    Button {
                                        store.setBackgroundStyle(style)
                                    } label: {
                                        if store.selectedDocument?.backgroundStyle == style {
                                            Label(backgroundTitle(style), systemImage: "checkmark")
                                        } else {
                                            Text(backgroundTitle(style))
                                        }
                                    }
                                }
                            }
                            Menu("外观") {
                                ForEach(["system", "light", "dark"], id: \.self) { value in
                                    Button {
                                        canvasAppearance = value
                                    } label: {
                                        let title = value == "system" ? "跟随系统"
                                            : value == "light" ? "浅色" : "深色"
                                        if canvasAppearance == value {
                                            Label(title, systemImage: "checkmark")
                                        } else {
                                            Text(title)
                                        }
                                    }
                                }
                            }
                            Toggle("显示缩略导航", isOn: $showsMiniMap)
                            if !selectedNodeIDs.isEmpty {
                                Button("属性") { showsInspector = true }
                                if selectedNodeIDs.count == 1,
                                   let selected = store.selectedDocument?.nodes.first(where: {
                                       selectedNodeIDs.contains($0.id)
                                           && $0.kind == .image && $0.asset != nil
                                   }) {
                                    Button("裁剪与变换", systemImage: "crop.rotate") {
                                        imageEditorPresentation = CanvasImageEditorPresentation(
                                            id: selected.id
                                        )
                                    }
                                }
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

    private func createNode(_ kind: CanvasNodeCreationKind, at point: CGPoint) {
        let nodeID: UUID
        switch kind {
        case .text: nodeID = store.addNote(at: point)
        case .stickyNote: nodeID = store.addStickyNote(at: point)
        case .card: nodeID = store.addCard(at: point)
        case .shape: nodeID = store.addShape(at: point)
        case .group: nodeID = store.addGroup(at: point)
        case .image: nodeID = store.addPlaceholder(kind: .image, at: point)
        case .video: nodeID = store.addPlaceholder(kind: .video, at: point)
        case .audio: nodeID = store.addPlaceholder(kind: .audio, at: point)
        case .file: nodeID = store.addPlaceholder(kind: .file, at: point)
        case .imageGeneration:
            nodeID = store.addGenerationTask(kind: .image, prompt: "", at: point)
        case .videoGeneration:
            nodeID = store.addGenerationTask(kind: .video, prompt: "", at: point)
        case .markdown:
            nodeID = store.addBuiltinNode(pluginID: "markdown", at: point)
        case .svg:
            nodeID = store.addBuiltinNode(pluginID: "svg", at: point)
        case .html:
            nodeID = store.addBuiltinNode(pluginID: "html", at: point)
        case .panorama3D:
            nodeID = store.addBuiltinNode(pluginID: "panorama3D", at: point)
        case .scene3D:
            nodeID = store.addScene3D(at: point)
        }
        selectedNodeIDs = [nodeID]
        selectedStrokeIDs.removeAll()
        selectedConnectionID = nil
        editingNodeID = [.text, .stickyNote, .card, .markdown, .svg, .html].contains(kind)
            ? nodeID : nil
        mode = .select
        if kind == .imageGeneration || kind == .videoGeneration { showsGeneration = true }
        if kind == .scene3D { directorPresentation = Canvas3DDirectorPresentation(nodeID: nodeID) }
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

    @ViewBuilder
    private func canvasBackground(style: CanvasBackgroundStyle, size: CGSize) -> some View {
        switch style {
        case .blank:
            EmptyView()
        case .grid:
            grid(size: size, dots: false)
        case .dots:
            grid(size: size, dots: true)
        }
    }

    private func backgroundTitle(_ style: CanvasBackgroundStyle) -> String {
        switch style {
        case .blank: "空白"
        case .grid: "网格"
        case .dots: "点阵"
        }
    }

    private func grid(size: CGSize, dots: Bool) -> some View {
        Canvas { context, _ in
            let spacing = max(18, 42 * scale)
            let xStart = pan.width.truncatingRemainder(dividingBy: spacing)
            let yStart = pan.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            if dots {
                var x = xStart
                while x < size.width {
                    var y = yStart
                    while y < size.height {
                        path.addEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                        y += spacing
                    }
                    x += spacing
                }
                context.fill(path, with: .color(.secondary.opacity(0.20)))
            } else {
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
                    let related = selectedNodeIDs.isEmpty
                        || selectedNodeIDs.contains(connection.sourceNodeID)
                        || selectedNodeIDs.contains(connection.destinationNodeID)
                    context.stroke(
                        path,
                        with: .color(selected ? FloeTheme.primary : FloeTheme.primary.opacity(related ? 0.72 : 0.18)),
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

    private func groupLayer(_ document: FloeCanvasDocument) -> some View {
        let containerIDs = Set(document.nodes.filter { $0.kind == .group }.map(\.id))
        let grouped = Dictionary(grouping: document.nodes.compactMap { node in
            node.groupID.flatMap { containerIDs.contains($0) ? nil : ($0, node) }
        }, by: { $0.0 })
        return ZStack {
            ForEach(grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { groupID in
                let nodes = grouped[groupID, default: []].map(\.1)
                if nodes.count > 1 {
                    let minX = nodes.map { $0.x - $0.width / 2 }.min() ?? 0
                    let maxX = nodes.map { $0.x + $0.width / 2 }.max() ?? 0
                    let minY = nodes.map { $0.y - $0.height / 2 }.min() ?? 0
                    let maxY = nodes.map { $0.y + $0.height / 2 }.max() ?? 0
                    let topLeft = screenPoint(CGPoint(x: minX - 24, y: minY - 36))
                    let bottomRight = screenPoint(CGPoint(x: maxX + 24, y: maxY + 24))
                    RoundedRectangle(cornerRadius: 20)
                        .fill(FloeTheme.primary.opacity(enteredGroupID == groupID ? 0.08 : 0.035))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(
                                    FloeTheme.primary.opacity(enteredGroupID == groupID ? 0.65 : 0.28),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                                )
                        }
                        .frame(
                            width: max(80, bottomRight.x - topLeft.x),
                            height: max(60, bottomRight.y - topLeft.y)
                        )
                        .position(
                            x: (topLeft.x + bottomRight.x) / 2,
                            y: (topLeft.y + bottomRight.y) / 2
                        )
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
                onAskAI: {
                    selectedNodeIDs = [node.id]
                    selectedConnectionID = nil
                    editingNodeID = nil
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
                            onOpenMenu: {
                                selectedNodeIDs = contextSelection(for: node)
                                selectedConnectionID = nil
                                editingNodeID = nil
                                withAnimation(.snappy) {
                                    pencilContextPoint = screenPoint(
                                        CGPoint(x: node.x, y: node.y + node.height / 2)
                                    )
                                }
                            },
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
                        CanvasNodeInlineAIComposer(
                            nodeTitle: node.text,
                            referenceCandidates: referenceCandidates(for: node.id)
                        ) { request, referenceNodeIDs in
                            selectedNodeIDs = Set(referenceNodeIDs).union([node.id])
                            pendingAgentRequest = CanvasAgentRequest(
                                nodeID: node.id,
                                prompt: request,
                                referenceNodeIDs: referenceNodeIDs
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
                if node.kind == .group {
                    enteredGroupID = node.id
                    selectedNodeIDs = [node.id]
                    editingNodeID = nil
                } else if let groupID = node.groupID, enteredGroupID != groupID {
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

    private func referenceCandidates(for nodeID: UUID) -> [FloeCanvasNode] {
        guard let document = store.selectedDocument else { return [] }
        let relatedIDs = Set(document.connections.compactMap { connection -> UUID? in
            if connection.sourceNodeID == nodeID { return connection.destinationNodeID }
            if connection.destinationNodeID == nodeID { return connection.sourceNodeID }
            return nil
        })
        let preferred = document.nodes.filter { relatedIDs.contains($0.id) }
        let remaining = document.nodes.filter { $0.id != nodeID && !relatedIDs.contains($0.id) }
        return Array((preferred + remaining).prefix(24))
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
        if node.kind == .group {
            let children = store.selectedDocument?.nodes.compactMap {
                $0.groupID == node.id ? $0.id : nil
            } ?? []
            return Set(children).union([node.id])
        }
        guard let groupID = node.groupID, enteredGroupID != groupID else { return [node.id] }
        let members = Set(store.selectedDocument?.nodes.compactMap {
            $0.groupID == groupID ? $0.id : nil
        } ?? [node.id])
        return members.union([groupID])
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
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    lastCanvasPointerPoint = location
                }
            }
            .simultaneousGesture(
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
                        case .connector: break
                        }
                    }
                    .onEnded { _ in
                        if mode == .hand {
                            panStart = pan
                            persistViewport()
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
                        persistViewport()
                    }
            )
            .highPriorityGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        guard mode == .select else { return }
                        lastCanvasPointerPoint = value.location
                        withAnimation(.snappy) { nodeCreationPoint = value.location }
                    }
                    .exclusively(before: SpatialTapGesture().onEnded { value in
                        handleCanvasTap(at: value.location)
                    })
            )
            .contextMenu {
                CanvasNodeCreationMenu { kind in
                    let point = lastCanvasPointerPoint ?? CGPoint(
                        x: size.width / 2, y: size.height / 2
                    )
                    createNode(kind, at: canvasPoint(point))
                }
                Divider()
                Button("粘贴", systemImage: "doc.on.clipboard", action: pasteFromClipboard)
                Button("从素材库导入", systemImage: "photo.on.rectangle.angled") {
                    materialTargetNodeID = nil
                    materialKindFilter = nil
                    showsMaterials = true
                }
                Button("适配画布", systemImage: "arrow.up.left.and.arrow.down.right") {
                    scale = 1
                    scaleStart = 1
                    pan = .zero
                    panStart = .zero
                }
            }
    }

    private func handleCanvasTap(at location: CGPoint) {
        lastCanvasPointerPoint = location
        nodeCreationPoint = nil
        switch mode {
        case .select:
            selectedNodeIDs.removeAll()
            selectedStrokeIDs.removeAll()
            selectedConnectionID = nil
            editingNodeID = nil
        case .hand, .pencil, .eraser, .connector:
            break
        }
    }

    @ViewBuilder
    private func pencilContextMenu(size: CGSize) -> some View {
        if !selectedNodeIDs.isEmpty {
            HStack(spacing: 5) {
                if selectedNodeIDs.count == 1, let nodeID = selectedNodeIDs.first {
                    Button("编辑", systemImage: "pencil") {
                        editingNodeID = nodeID
                        pencilContextPoint = nil
                    }
                }
                Button("复制", systemImage: "plus.square.on.square") {
                    selectedNodeIDs = store.duplicateNodes(selectedNodeIDs)
                    pencilContextPoint = nil
                }
                Button("连接", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    connectionStartID = selectedNodeIDs.first
                    mode = .connector
                    pencilContextPoint = nil
                }
                Menu("更多", systemImage: "ellipsis.circle") {
                    if selectedNodeIDs.count == 1, let nodeID = selectedNodeIDs.first {
                        Button("节点内提问", systemImage: "sparkles") {
                            pendingAgentRequest = CanvasAgentRequest(nodeID: nodeID, prompt: "")
                            showsAgent = true
                            isAgentCollapsed = false
                            pencilContextPoint = nil
                        }
                    }
                    if let selectedNode = store.selectedDocument?.nodes.first(where: {
                        selectedNodeIDs.contains($0.id)
                    }) {
                        Button(selectedNode.isLocked ? "解锁" : "锁定",
                               systemImage: selectedNode.isLocked ? "lock.open" : "lock") {
                            store.setLocked(selectedNodeIDs, locked: !selectedNode.isLocked)
                            pencilContextPoint = nil
                        }
                    }
                    Button("移到最前", systemImage: "arrow.up.to.line") {
                        store.changeLayer(selectedNodeIDs, bringToFront: true)
                        pencilContextPoint = nil
                    }
                    Button("移到最后", systemImage: "arrow.down.to.line") {
                        store.changeLayer(selectedNodeIDs, bringToFront: false)
                        pencilContextPoint = nil
                    }
                    if selectedNodeIDs.count > 1 {
                        Button("分组", systemImage: "square.3.layers.3d") {
                            store.group(selectedNodeIDs)
                            pencilContextPoint = nil
                        }
                    } else if let selectedNode = store.selectedDocument?.nodes.first(where: {
                        selectedNodeIDs.contains($0.id)
                    }), selectedNode.groupID != nil {
                        Button("解除分组", systemImage: "square.2.layers.3d") {
                            store.ungroup(selectedNodeIDs)
                            pencilContextPoint = nil
                        }
                    }
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    deleteSelection()
                    pencilContextPoint = nil
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        } else if !selectedStrokeIDs.isEmpty || store.hasNativeInk {
            HStack(spacing: 5) {
                Button("整理笔迹", systemImage: "wand.and.rays") {
                    interpretSelectedInk()
                    pencilContextPoint = nil
                }
                Button("橡皮", systemImage: "eraser") {
                    mode = .eraser
                    pencilContextPoint = nil
                }
                Button("新建卡片", systemImage: "note.text.badge.plus") {
                    createNode(.card, at: canvasPoint(pencilContextPoint ?? CGPoint(
                        x: size.width / 2, y: size.height / 2
                    )))
                    pencilContextPoint = nil
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        } else {
            HStack(spacing: 5) {
                Button("画笔", systemImage: "pencil.tip") {
                    mode = .pencil
                    showsPencilPalette = true
                    pencilContextPoint = nil
                }
                Button("卡片", systemImage: "note.text.badge.plus") {
                    createNode(.card, at: canvasPoint(pencilContextPoint ?? CGPoint(
                        x: size.width / 2, y: size.height / 2
                    )))
                    pencilContextPoint = nil
                }
                Button("文本", systemImage: "textformat") {
                    createNode(.text, at: canvasPoint(pencilContextPoint ?? CGPoint(
                        x: size.width / 2, y: size.height / 2
                    )))
                    pencilContextPoint = nil
                }
                Button("更多节点", systemImage: "plus") {
                    nodeCreationPoint = pencilContextPoint
                    pencilContextPoint = nil
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        }
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
                CanvasNodeCreationMenu { kind in
                    createNode(kind, at: canvasPoint(CGPoint(
                        x: size.width / 2,
                        y: size.height / 2
                    )))
                }
                Divider()
                Button("从素材库添加…", systemImage: "photo.on.rectangle.angled") {
                    materialTargetNodeID = nil
                    materialKindFilter = [.image, .video, .audio, .file]
                    showsMaterials = true
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("添加节点")
            .accessibilityHint("显示全部可用节点类型")
            .accessibilityIdentifier("canvas.node.create.bottom")

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
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvas.node.toolbar")
        }
    }

    private var selectedGroupID: UUID? {
        let selectedNodes = store.selectedDocument?.nodes.filter { selectedNodeIDs.contains($0.id) } ?? []
        if let container = selectedNodes.first(where: { $0.kind == .group }) {
            return container.id
        }
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
                persistViewport()
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
                persistViewport()
            },
            zoomOut: {
                scale = max(0.3, scale - 0.2)
                scaleStart = scale
                persistViewport()
            },
            resetView: {
                scale = 1; scaleStart = 1; pan = .zero; panStart = .zero
                persistViewport()
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

    private func restoreViewport() {
        guard let viewport = store.project.viewports[store.project.selectedDocumentID] else { return }
        scale = viewport.scale
        scaleStart = viewport.scale
        pan = CGSize(
            width: -viewport.center.x * viewport.scale,
            height: -viewport.center.y * viewport.scale
        )
        panStart = pan
    }

    private func persistViewport() {
        store.updateViewport(
            center: CanvasPoint(x: -pan.width / scale, y: -pan.height / scale),
            scale: scale
        )
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
    let onSqueeze: @MainActor (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onSqueeze: onSqueeze)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onSqueeze = onSqueeze
    }

    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onTap: @MainActor () -> Void
        var onSqueeze: @MainActor (CGPoint?) -> Void

        init(
            onTap: @escaping @MainActor () -> Void,
            onSqueeze: @escaping @MainActor (CGPoint?) -> Void
        ) {
            self.onTap = onTap
            self.onSqueeze = onSqueeze
        }

        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap tap: UIPencilInteraction.Tap
        ) {
            onTap()
        }

        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .ended else { return }
            onSqueeze(squeeze.hoverPose?.location)
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

private struct CanvasLocalImageEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CanvasDocumentStore
    let node: FloeCanvasNode
    let onSave: (UUID) -> Void

    @State private var cropInset = 0.0
    @State private var rotation = 0.0
    @State private var preview: UIImage?
    @State private var sourceImage: CGImage?
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ContentUnavailableView(
                            "图片不可用", systemImage: "photo",
                            description: Text("请先确认这份素材已下载到本机。")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FloeTheme.readingSurface)

                Form {
                    Section("裁剪") {
                        Slider(value: $cropInset, in: 0...0.3, step: 0.025)
                        LabeledContent("四边内缩", value: "\(Int(cropInset * 100))%")
                        HStack {
                            Button("原图") { cropInset = 0 }
                            Button("轻裁 10%") { cropInset = 0.1 }
                            Button("聚焦 20%") { cropInset = 0.2 }
                        }
                    }
                    Section("旋转") {
                        Slider(value: $rotation, in: -180...180, step: 1)
                        LabeledContent("角度", value: "\(Int(rotation))°")
                        HStack {
                            Button("左转 90°") { rotation = -90 }
                            Button("复位") { rotation = 0 }
                            Button("右转 90°") { rotation = 90 }
                        }
                    }
                    Text("保存会创建一份新的素材和结果节点，原图与连接关系保持不变。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: 330)
            }
            .navigationTitle("裁剪与变换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveDerivedImage() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("保存副本") }
                    }
                    .disabled(sourceImage == nil || isSaving)
                }
            }
            .task { loadSource() }
            .onChange(of: cropInset) { _, _ in renderPreview() }
            .onChange(of: rotation) { _, _ in renderPreview() }
            .alert("无法编辑图片", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("完成", role: .cancel) {} } message: { Text(error ?? "") }
        }
    }

    private func loadSource() {
        guard let url = CanvasAssetNodeContent.localURL(for: node),
              let image = UIImage(contentsOfFile: url.path)?.cgImage else {
            sourceImage = nil
            preview = nil
            return
        }
        sourceImage = image
        renderPreview()
    }

    private func renderPreview() {
        guard let sourceImage else { return }
        do {
            var rendered = sourceImage
            if cropInset > 0 {
                rendered = try ImagePipeline().apply(
                    .crop(rect: .init(
                        x: cropInset, y: cropInset,
                        width: 1 - cropInset * 2, height: 1 - cropInset * 2
                    )),
                    to: rendered
                )
            }
            if rotation != 0 {
                rendered = try ImagePipeline().apply(.rotate(degrees: rotation), to: rendered)
            }
            preview = UIImage(cgImage: rendered)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func saveDerivedImage() async {
        guard let preview, let data = preview.pngData() else { return }
        isSaving = true
        defer { isSaving = false }
        var writtenTarget: URL?
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let directory = support.appendingPathComponent(
                "FloeAgent/Materials", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let assetID = UUID()
            let filename = "\(assetID.uuidString)-canvas-edit.png"
            let target = directory.appendingPathComponent(filename)
            try data.write(to: target, options: .atomic)
            writtenTarget = target
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await environment.creativeAssetStore.save(CreativeAssetRecord(
                id: assetID, contentHash: hash, kind: .image,
                displayName: "\(node.text.isEmpty ? "画布图片" : node.text) 编辑",
                mimeType: "image/png", localRelativePath: "Materials/\(filename)",
                byteCount: Int64(data.count), tags: ["画布编辑"], referenceCount: 0
            ))
            let reference = CanvasAssetReference(
                id: assetID, contentHash: hash,
                localRelativePath: "Materials/\(filename)",
                mimeType: "image/png", byteCount: Int64(data.count)
            )
            let resultID = store.addAsset(
                reference, kind: .image,
                at: CGPoint(x: node.x + node.width + 100, y: node.y)
            )
            store.updateNodeMetadata(resultID, values: [
                "derivedFromNodeID": node.id.uuidString,
                "cropInset": String(cropInset),
                "rotationDegrees": String(rotation)
            ])
            store.connect(node.id, to: resultID, kind: .generatedFrom)
            onSave(resultID)
        } catch {
            if let writtenTarget {
                try? FileManager.default.removeItem(at: writtenTarget)
            }
            self.error = error.localizedDescription
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
    let onAskAI: () -> Void
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
        .shadow(color: node.kind == .group ? .clear : .black.opacity(0.08), radius: 8, y: 3)
        .contextMenu {
            Button("编辑", systemImage: "pencil", action: onBeginEditing)
            Button("节点内提问", systemImage: "sparkles", action: onAskAI)
            Button("复制", systemImage: "plus.square.on.square", action: onDuplicate)
            Button("连接", systemImage: "point.topleft.down.to.point.bottomright.curvepath", action: onConnect)
            if let onOpen3D {
                Button("打开 3D 导演台", systemImage: "cube.transparent", action: onOpen3D)
            }
            Divider()
            Button(node.isLocked ? "解锁" : "锁定", systemImage: node.isLocked ? "lock.open" : "lock", action: onToggleLock)
            Button("移到最前", systemImage: "arrow.up.to.line", action: onBringToFront)
            Button("移到最后", systemImage: "arrow.down.to.line", action: onSendToBack)
            if node.kind == .group || node.groupID != nil {
                Button("解除分组", systemImage: "square.2.layers.3d", action: onUngroup)
            } else {
                Button("分组", systemImage: "square.3.layers.3d", action: onGroup)
            }
            Divider()
            Button("删除节点", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier("canvas.node.\(node.id.uuidString)")
    }

    private var nodeBackground: Color {
        if node.kind == .group { return .clear }
        return node.kind == .stickyNote
            ? Color(uiColor: .systemYellow).opacity(0.24)
            : Color(uiColor: .secondarySystemBackground)
    }

    @ViewBuilder
    private var nodeContent: some View {
        if let pluginID = node.metadata["builtinPlugin"] {
            builtinNodeContent(pluginID)
        } else {
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
        case .card:
            VStack(alignment: .leading, spacing: 8) {
                Label("基础卡片", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Divider()
                if isEditing {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                } else {
                    Text(text.isEmpty ? "卡片内容" : text)
                        .font(.body)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
            }
            .padding(14)
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
            VStack(alignment: .leading) {
                Label(text.isEmpty ? "分组" : text, systemImage: "square.3.layers.3d")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FloeTheme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
            .contentShape(Rectangle())
        case .generationTask:
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: generationStateIcon)
                        .foregroundStyle(generationStateColor)
                    Text(text.isEmpty ? "生成配置" : text)
                        .font(.headline)
                    Spacer()
                    Text(generationStateTitle)
                        .font(FloeTheme.Typography.metadata.weight(.semibold))
                        .foregroundStyle(generationStateColor)
                }
                if let prompt = node.metadata["generationPrompt"], !prompt.isEmpty {
                    Text(prompt)
                        .font(.subheadline)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    if let ratio = node.metadata["generationAspectRatio"], !ratio.isEmpty {
                        generationTag(ratio)
                    }
                    if let quality = node.metadata["generationQuality"], !quality.isEmpty {
                        generationTag(quality)
                    }
                    if let count = node.metadata["generationCount"], count != "1" {
                        generationTag("×\(count)")
                    }
                }
                if node.metadata["generationState"] == "failed" {
                    Text(node.metadata["generationError"] ?? "生成失败，选中后重新配置")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("选中此节点可查看配置或重新生成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
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
    }

    private var generationStateTitle: String {
        switch node.metadata["generationState"] {
        case "ready": "完成"
        case "submitted", "running", "preparing": "生成中"
        case "failed", "submitFailed": "失败"
        default: "待配置"
        }
    }

    private var generationStateIcon: String {
        switch node.metadata["generationState"] {
        case "ready": "checkmark.circle.fill"
        case "submitted", "running", "preparing": "wand.and.stars"
        case "failed", "submitFailed": "exclamationmark.circle.fill"
        default: "slider.horizontal.3"
        }
    }

    private var generationStateColor: Color {
        switch node.metadata["generationState"] {
        case "ready": .green
        case "failed", "submitFailed": .red
        default: FloeTheme.primary
        }
    }

    private func generationTag(_ value: String) -> some View {
        Text(value)
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private func builtinNodeContent(_ pluginID: String) -> some View {
        switch pluginID {
        case "markdown":
            if isEditing {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(10)
            } else {
                ScrollView {
                    Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
            }
        case "svg":
            if isEditing {
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                CanvasSafeMarkupView(markup: text, wrapsAsSVG: true)
            }
        case "html":
            if isEditing {
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                CanvasSafeMarkupView(markup: text, wrapsAsSVG: false)
            }
        case "panorama3D":
            CanvasPanoramaNode(assetURL: CanvasAssetNodeContent.localURL(for: node))
        default:
            Label("不支持的内置节点", systemImage: "exclamationmark.triangle")
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

    static func localURL(for node: FloeCanvasNode) -> URL? {
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

    private var fileURL: URL? { Self.localURL(for: node) }

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

/// Static HTML/SVG renderer for bundled node types. JavaScript and external
/// navigation stay disabled, so these nodes cannot become a remote-code
/// plugin channel.
private struct CanvasSafeMarkupView: UIViewRepresentable {
    let markup: String
    let wrapsAsSVG: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let content = wrapsAsSVG ? markup : "<main>\(markup)</main>"
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;padding:0;background:transparent;color:#222;font:-apple-system-body}main{padding:14px}svg{width:100%;height:100%}</style>
        </head><body>\(content)</body></html>
        """
        if context.coordinator.lastMarkup != html {
            context.coordinator.lastMarkup = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastMarkup = ""
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}

private struct CanvasPanoramaNode: UIViewRepresentable {
    let assetURL: URL?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .secondarySystemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 8)
        sphere.segmentCount = 96
        sphere.firstMaterial?.isDoubleSided = true
        sphere.firstMaterial?.cullMode = .front
        sphere.firstMaterial?.diffuse.contents = assetURL.flatMap { UIImage(contentsOfFile: $0.path) }
            ?? UIColor.secondarySystemBackground
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.scale = SCNVector3(-1, 1, 1)
        scene.rootNode.addChildNode(sphereNode)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 72
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.scene = scene
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
    var referenceNodeIDs: [UUID] = []
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
    let referenceCandidates: [FloeCanvasNode]
    let onSubmit: (String, [UUID]) -> Void
    @State private var prompt = ""
    @State private var referenceNodeIDs = Set<UUID>()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(FloeTheme.primary)
            if !referenceCandidates.isEmpty {
                Menu {
                    ForEach(referenceCandidates) { node in
                        Button {
                            if referenceNodeIDs.contains(node.id) {
                                referenceNodeIDs.remove(node.id)
                            } else {
                                referenceNodeIDs.insert(node.id)
                            }
                        } label: {
                            Label(
                                node.text.isEmpty ? node.kind.rawValue : String(node.text.prefix(28)),
                                systemImage: referenceNodeIDs.contains(node.id)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                } label: {
                    Text(referenceNodeIDs.isEmpty ? "@" : "@\(referenceNodeIDs.count)")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("引用节点")
            }
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
        let references = referenceNodeIDs.sorted { $0.uuidString < $1.uuidString }
        referenceNodeIDs.removeAll()
        onSubmit(request, references)
    }
}

private struct CanvasMiniMap: View {
    let document: FloeCanvasDocument
    let viewportCenter: CanvasPoint
    let viewportSize: CanvasSize
    let onNavigate: (CanvasPoint, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let mapGeometry = CanvasMiniMapGeometry(
                document: document,
                viewportCenter: viewportCenter,
                viewportSize: viewportSize,
                mapSize: CanvasSize(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            )
            let mappedViewport = mapGeometry.mapSize(viewportSize)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
                ForEach(document.strokes) { stroke in
                    Path { path in
                        guard let first = stroke.points.first else { return }
                        let start = mapGeometry.mapPoint(first)
                        path.move(to: CGPoint(x: start.x, y: start.y))
                        for point in stroke.points.dropFirst() {
                            let mapped = mapGeometry.mapPoint(point)
                            path.addLine(to: CGPoint(x: mapped.x, y: mapped.y))
                        }
                    }
                    .stroke(
                        Color.secondary.opacity(0.55),
                        style: StrokeStyle(
                            lineWidth: max(1, stroke.width * mapGeometry.scale),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
                ForEach(document.nodes) { node in
                    let mapped = mapGeometry.mapPoint(CanvasPoint(x: node.x, y: node.y))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(node.kind == .image || node.kind == .video
                              ? FloeTheme.primary.opacity(0.65)
                              : Color.secondary.opacity(0.42))
                        .frame(
                            width: max(3, node.width * mapGeometry.scale),
                            height: max(3, node.height * mapGeometry.scale)
                        )
                        .position(x: mapped.x, y: mapped.y)
                }
                let mappedCenter = mapGeometry.mapPoint(viewportCenter)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(FloeTheme.primary, lineWidth: 1.5)
                    .frame(
                        width: min(geometry.size.width, max(8, mappedViewport.width)),
                        height: min(geometry.size.height, max(8, mappedViewport.height))
                    )
                    .position(x: mappedCenter.x, y: mappedCenter.y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = mapGeometry.canvasPoint(CanvasPoint(value.location))
                        onNavigate(point, false)
                    }
                    .onEnded { value in
                        let point = mapGeometry.canvasPoint(CanvasPoint(value.location))
                        onNavigate(point, true)
                    }
            )
        }
        .frame(width: 180, height: 112)
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityLabel("画布缩略导航")
        .accessibilityHint("点按或拖动以移动当前画布视口")
    }
}

private struct CanvasNodeSelectionChrome: View {
    let node: FloeCanvasNode
    let onOpenMenu: () -> Void
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
                .strokeBorder(Color.black.opacity(0.001), lineWidth: 22)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture(count: 2, perform: onOpenMenu)
                .accessibilityLabel("打开节点操作菜单")
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
    let selectedNodeIDs: Set<UUID>
    @Binding var pendingRequest: CanvasAgentRequest?
    let availableSize: CGSize
    @Binding var offset: CGSize
    @Binding var isCollapsed: Bool
    let onClose: () -> Void

    @State private var isRunning = false
    @State private var setupError: String?
    @State private var dragOrigin = CGSize.zero
    @State private var isDragging = false
    @State private var activeConversationID: UUID?
    @State private var preparedDocumentID: UUID?

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
                Divider()
                if let activeConversationID {
                    SharedCanvasAgentConversation(
                        conversationID: activeConversationID,
                        center: center,
                        store: store,
                        workspace: workspace,
                        contextSnapshot: contextSnapshot,
                        selectedNodeIDs: selectedNodeIDs,
                        pendingRequest: $pendingRequest,
                        availableModels: toolCapableModels,
                        isRunning: $isRunning
                    )
                    .id(activeConversationID)
                } else {
                    ContentUnavailableView(
                        setupError == nil ? "正在准备画布助手…" : "无法准备画布助手",
                        systemImage: setupError == nil ? "sparkles" : "exclamationmark.triangle",
                        description: setupError.map(Text.init)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 24, y: 12)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: store.project.selectedDocumentID) {
            await prepare(documentID: store.project.selectedDocumentID)
        }
    }

    private var floatingHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FloeTheme.primary)
                .frame(width: 30, height: 30)
                .background(FloeTheme.primary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("画布助手")
                    .font(.subheadline.weight(.semibold))
                Text(isRunning ? "正在处理" : "连接当前画布")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                withAnimation(.snappy) { isCollapsed.toggle() }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "展开画布助手" : "收起画布助手")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭画布助手")
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(FloeTheme.chromeMaterial)
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
        let compact = availableSize.width < 620
        let panelWidth = isCollapsed
            ? min(232, availableSize.width - 16)
            : (compact ? max(280, availableSize.width - 16) : min(392, max(320, availableSize.width - 24)))
        let panelHeight = isCollapsed
            ? 56
            : min(compact ? 520 : 640, max(300, availableSize.height - 24))
        let anchorX = compact ? availableSize.width / 2 : availableSize.width - panelWidth / 2 - 12
        let anchorY = compact ? availableSize.height - panelHeight / 2 - 12 : panelHeight / 2 + 12
        let minimumX = 12 + panelWidth / 2 - anchorX
        let maximumX = availableSize.width - 12 - panelWidth / 2 - anchorX
        let minimumY = 12 + panelHeight / 2 - anchorY
        let maximumY = availableSize.height - 12 - panelHeight / 2 - anchorY
        return CGSize(
            width: min(maximumX, max(minimumX, proposed.width)),
            height: min(maximumY, max(minimumY, proposed.height))
        )
    }

    @MainActor
    private func prepare(documentID: UUID) async {
        if let preparedDocumentID, preparedDocumentID != documentID {
            pendingRequest = nil
        }
        preparedDocumentID = documentID
        activeConversationID = nil
        isRunning = false
        setupError = nil
        mcpCenter.activate()
        await center.reload()
        guard !Task.isCancelled, store.project.selectedDocumentID == documentID else { return }
        if toolCapableModels.isEmpty {
            setupError = "请先启用一个支持工具调用的模型。"
            return
        }
        do {
            let conversationID = try await ensureConversationAndPolicy(documentID: documentID)
            guard !Task.isCancelled, store.project.selectedDocumentID == documentID else { return }
            activeConversationID = conversationID
            setupError = nil
        } catch {
            guard !Task.isCancelled else { return }
            setupError = error.localizedDescription
        }
    }

    @MainActor
    private func ensureConversationAndPolicy(documentID: UUID) async throws -> UUID {
        let workspaceStore = SQLiteWorkspaceStore(database: environment.database)
        let conversationID: UUID
        if let existing = store.agentConversationID(for: documentID),
           try await environment.conversationStore.conversation(id: existing) != nil {
            conversationID = existing
        } else {
            let id = UUID()
            let now = Date()
            let documentName = store.project.documents.first(where: { $0.id == documentID })?.name
                ?? "画布"
            do {
                try await environment.conversationStore.saveConversation(ConversationRecord(
                    id: id,
                    title: "\(CanvasAgentIdentity.conversationTitlePrefix)\(store.project.name) · \(documentName)",
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
                } else {
                    // Private canvases still need a canonical private-task
                    // execution context. It is app-owned and hidden with the
                    // assistant conversation; it is not a project binding.
                    _ = try await workspaceStore.ensureWorkspace(
                        conversationID: id,
                        title: "画布助手 · \(store.project.name) · \(documentName)"
                    )
                }
                store.setAgentConversationID(id, for: documentID)
                conversationID = id
            } catch {
                try? await environment.conversationStore.deleteConversation(id: id)
                throw error
            }
        }

        // Repair canvas-agent conversations created by older builds before
        // private canvas ownership was durable. Run launch is fail-closed when
        // the canonical workspace is absent, so heal it before policy/run use.
        if try await workspaceStore.workspaceID(conversationID: conversationID) == nil {
            if let workspace {
                try await workspaceStore.linkConversation(
                    workspaceID: workspace.id,
                    conversationID: conversationID
                )
            } else {
                _ = try await workspaceStore.ensureWorkspace(
                    conversationID: conversationID,
                    title: "画布助手 · \(store.project.name)"
                )
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

}

/// Canvas presentation for the same canonical conversation controller used by
/// ordinary tasks. Only contextual goal composition and result insertion are
/// canvas-specific; run ownership and recovery remain in ConversationCenter.
private struct SharedCanvasAgentConversation: View {
    @StateObject private var viewModel: ThreadDetailViewModel
    @ObservedObject var store: CanvasDocumentStore

    let workspace: WorkspaceRecord?
    let contextSnapshot: String
    let selectedNodeIDs: Set<UUID>
    @Binding var pendingRequest: CanvasAgentRequest?
    let availableModels: [ModelProfile]
    @Binding var isRunning: Bool

    @State private var prompt = ""
    @State private var insertedRunIDs = Set<UUID>()

    init(
        conversationID: UUID,
        center: ConversationCenter,
        store: CanvasDocumentStore,
        workspace: WorkspaceRecord?,
        contextSnapshot: String,
        selectedNodeIDs: Set<UUID>,
        pendingRequest: Binding<CanvasAgentRequest?>,
        availableModels: [ModelProfile],
        isRunning: Binding<Bool>
    ) {
        _viewModel = StateObject(wrappedValue: ThreadDetailViewModel(
            conversationID: conversationID,
            center: center
        ))
        self.store = store
        self.workspace = workspace
        self.contextSnapshot = contextSnapshot
        self.selectedNodeIDs = selectedNodeIDs
        _pendingRequest = pendingRequest
        self.availableModels = availableModels
        _isRunning = isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .task {
            viewModel.agentMode = .agent
            viewModel.selectedProjectID = workspace?.id
            await viewModel.load()
            if !availableModels.contains(where: { $0.id == viewModel.selectedModelID }) {
                viewModel.selectedModelID = availableModels.first?.id
            }
            isRunning = viewModel.isRunning
            await consumePendingRequest()
        }
        .onChange(of: viewModel.isRunning) { _, value in isRunning = value }
        .onChange(of: pendingRequest?.id) { _, _ in
            Task { await consumePendingRequest() }
        }
        .onDisappear { viewModel.stopLiveUpdates() }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if viewModel.messages.isEmpty, !viewModel.isRunning {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(FloeTheme.primary)
                        Text("从一个想法开始")
                            .font(.headline)
                        Text("搜索资料、整理选中内容，或直接生成图片和视频。提示词、配置与结果会留在画布上。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            suggestion("整理选中内容")
                            suggestion("生成一张配图")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                }
                ForEach(Array(viewModel.timeline.suffix(30))) { item in
                    timelineRow(item)
                }
                if viewModel.isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                        if let state = viewModel.liveStateName {
                            Text(RunStateLocalizer.title(for: state))
                        } else {
                            Text("正在处理…")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let error = viewModel.actionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if availableModels.count > 1 {
                Picker("画布助手模型", selection: $viewModel.selectedModelID) {
                    ForEach(availableModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .pickerStyle(.menu)
                .font(FloeTheme.Typography.metadata)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("描述要查找、整理或生成的内容", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit { Task { await submit() } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Button {
                    Task { await submit() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(FloeTheme.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || viewModel.selectedModelID == nil)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack {
                if viewModel.isRunning {
                    Picker("运行中输入", selection: $viewModel.runningInputMode) {
                        Text("排队").tag(RunningInputMode.queue)
                        Text("引导当前任务").tag(RunningInputMode.steer)
                    }
                    .pickerStyle(.menu)
                    Button("停止", systemImage: "stop.fill") {
                        Task { await viewModel.cancel() }
                    }
                    .buttonStyle(.bordered)
                } else if viewModel.canContinue {
                    Button("继续", systemImage: "arrow.clockwise") {
                        Task { await viewModel.retry() }
                    }
                    .buttonStyle(.bordered)
                }
                if let runID = viewModel.selectedRunID,
                   !insertedRunIDs.contains(runID),
                   let answer = latestAnswer(runID: runID) {
                    Button("加入画布", systemImage: "rectangle.stack.badge.plus") {
                        store.addResearchNote(
                            text: answer,
                            sourceURLs: extractURLs(from: answer),
                            runID: runID
                        )
                        insertedRunIDs.insert(runID)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if !viewModel.isRunning {
                    Text("Return 发送")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(FloeTheme.chromeMaterial)
    }

    @ViewBuilder
    private func timelineRow(_ item: ThreadTimelineItem) -> some View {
        switch item {
        case .userMessage(let message):
            messageBubble(title: "你", text: displayContent(message), isUser: true)
        case .assistantMessage(let text, _):
            messageBubble(title: "画布助手", text: text, isUser: false)
        case .stepGroup(let events, let isLatest):
            StepGroupView(
                events: events,
                isLatest: isLatest,
                isLive: viewModel.isRunning && isLatest,
                hasError: events.contains { $0.kind == .error },
                pendingApprovals: viewModel.pendingApprovals
            ) { approval, decision in
                Task { await viewModel.resolve(approval, decision: decision) }
            }
        case .event(let event), .terminal(let event):
            ThreadEventView(
                event: event,
                isLive: viewModel.isRunning,
                hasError: event.kind == .error
            )
        case .missingFinalMessage:
            Label("模型未返回最终文本", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .liveReasoning, .liveAssistantTail, .liveThinking:
            HStack { ProgressView(); Text("正在处理…") }
                .font(.caption).foregroundStyle(.secondary)
        case .approval(let approval):
            ApprovalCardView(approval: approval) { decision in
                Task { await viewModel.resolve(approval, decision: decision) }
            }
        }
    }

    private func messageBubble(title: String, text: String, isUser: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isUser ? 11 : 0)
        .background(
            isUser ? FloeTheme.primary.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) { prompt = text }
            .font(FloeTheme.Typography.metadata)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    @MainActor
    private func submit(targetNodeID: UUID? = nil) async {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        let goal = researchGoal(request)
        let wasRunning = viewModel.isRunning
        prompt = ""
        await viewModel.send(
            goalOverride: goal,
            runSurface: .canvas,
            canvasContext: CanvasRunContextSeed(
                canvasID: store.project.id,
                documentID: store.selectedDocument?.id,
                selectedNodeIDs: selectedNodeIDs.sorted { $0.uuidString < $1.uuidString },
                projectRevision: store.project.revision
            )
        )
        if viewModel.actionError != nil, !viewModel.isRunning {
            prompt = request
        }
        // A queue/steer submission joins an existing run and returns before
        // that input has a distinct answer. Never attach the previous answer
        // to the requested node; the finished result remains available via
        // the explicit Add to Canvas action.
        guard !wasRunning else { return }
        guard let runID = viewModel.selectedRunID,
              let answer = latestAnswer(runID: runID) else { return }
        if let targetNodeID {
            _ = store.applyAgentResult(text: answer, to: targetNodeID, runID: runID)
            insertedRunIDs.insert(runID)
        }
    }

    @MainActor
    private func consumePendingRequest() async {
        guard let request = pendingRequest else { return }
        prompt = request.prompt
        if !request.referenceNodeIDs.isEmpty {
            prompt += "\n\n引用节点：" + request.referenceNodeIDs
                .map { "@node:\($0.uuidString)" }
                .joined(separator: " ")
        }
        pendingRequest = nil
        await submit(targetNodeID: request.nodeID)
    }

    private func latestAnswer(runID: UUID) -> String? {
        viewModel.messages.last(where: {
            $0.role == "assistant" && $0.runID == runID
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayContent(_ message: PersistedMessage) -> String {
        guard message.role == "user",
              let range = message.content.range(of: "User request:\n") else {
            return message.content
        }
        return String(message.content[range.upperBound...])
    }

    private func extractURLs(from text: String) -> [String] {
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

    private func researchGoal(_ request: String) -> String {
        """
        你是 Floe 原生画布里的创作助手。理解当前选中的节点、相邻关系和用户目标；需要资料时可以搜索网页或读取公开链接，需要素材时使用画布素材与媒体生成工具。只使用本次实际提供的工具，保留来源，并把结果作为可编辑画布节点。

        图片或视频生成必须使用唯一的 canvas.generate：一次调用会创建或复用“提示词 → 生成配置 → 结果”节点链。工具返回 ready、submitted 或 reused 都表示本次提交已经完成，禁止在同一轮以相同参数再次调用；返回 failed 时也不要原样重试，应说明失败并让用户从配置节点发起新的重试。

        当前画布上下文：
        \(contextSnapshot)

        User request:
        \(request)
        """
    }
}

private struct CanvasPromptRecord: Codable, Identifiable, Hashable {
    let id: String
    let sourceId: String
    let title: String
    let prompt: String
    let description: String?
    let coverUrl: String?
    let referenceImageUrls: [String]?
    let tags: [String]
    let author: String?
    let sourceUrl: String?
    let imageMode: String?
    let imageModel: String?

    private enum CodingKeys: String, CodingKey {
        case id, sourceId, title, prompt, description, coverUrl
        case referenceImageUrls, tags, author, sourceUrl, imageMode, imageModel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceId = try values.decodeIfPresent(String.self, forKey: .sourceId) ?? "unknown"
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "未命名提示词"
        prompt = try values.decode(String.self, forKey: .prompt)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        coverUrl = try values.decodeIfPresent(String.self, forKey: .coverUrl)
        referenceImageUrls = try values.decodeIfPresent([String].self, forKey: .referenceImageUrls)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        author = try values.decodeIfPresent(String.self, forKey: .author)
        sourceUrl = try values.decodeIfPresent(String.self, forKey: .sourceUrl)
        imageMode = try values.decodeIfPresent(String.self, forKey: .imageMode)
        imageModel = try values.decodeIfPresent(String.self, forKey: .imageModel)
    }
}

@MainActor
private final class CanvasPromptLibraryStore: ObservableObject {
    @Published private(set) var records: [CanvasPromptRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published var notice: String?

    private static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/yukkcat/image-prompts/main/dist/prompts.json"
    )!
    private static let maximumPayloadBytes = 32 * 1_024 * 1_024

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if records.isEmpty, let cached = try? Data(contentsOf: cacheURL),
           let decoded = try? Self.decode(cached) {
            records = decoded
            lastUpdated = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: Self.remoteURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard data.count <= Self.maximumPayloadBytes else {
                throw FloeError.invalidConfiguration("提示词数据超过 32 MB 安全上限。")
            }
            let decoded = try Self.decode(data)
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
            records = decoded
            lastUpdated = Date()
            notice = nil
        } catch {
            notice = records.isEmpty
                ? "提示词库暂时无法载入：\(error.localizedDescription)"
                : "网络刷新失败，正在使用本机缓存。"
        }
    }

    private static func decode(_ data: Data) throws -> [CanvasPromptRecord] {
        let decoded = try JSONDecoder().decode([CanvasPromptRecord].self, from: data)
        return decoded.filter {
            !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FloeAgent/PromptLibrary/prompts.json")
    }
}

private struct CanvasPromptLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CanvasPromptLibraryStore()
    @State private var search = ""
    @State private var selectedSource = ""
    @State private var selectedTag = ""
    @State private var detail: CanvasPromptRecord?

    let onChoose: (CanvasPromptRecord) -> Void

    private var sources: [String] {
        Array(Set(store.records.map(\.sourceId))).sorted()
    }

    private var tags: [String] {
        let candidates = selectedSource.isEmpty
            ? store.records
            : store.records.filter { $0.sourceId == selectedSource }
        return Array(Set(candidates.flatMap(\.tags))).sorted()
    }

    private var filtered: [CanvasPromptRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return store.records.filter { record in
            (selectedSource.isEmpty || record.sourceId == selectedSource)
                && (selectedTag.isEmpty || record.tags.contains(selectedTag))
                && (query.isEmpty || [
                    record.title, record.prompt, record.description ?? "",
                    record.author ?? "", record.tags.joined(separator: " ")
                ].joined(separator: " ").localizedLowercase.contains(query))
        }
    }

    var body: some View {
        List {
            if let notice = store.notice {
                Label(notice, systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(store.records.isEmpty ? .red : .secondary)
            }
            if !sources.isEmpty {
                Section {
                    Picker("来源", selection: $selectedSource) {
                        Text("全部来源").tag("")
                        ForEach(sources, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("标签", selection: $selectedTag) {
                        Text("全部标签").tag("")
                        ForEach(tags, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section {
                ForEach(filtered) { record in
                    Button { detail = record } label: {
                        HStack(alignment: .top, spacing: 12) {
                            promptCover(record, size: CGSize(width: 82, height: 82))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(record.prompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                HStack(spacing: 6) {
                                    Text(record.sourceId)
                                    if let tag = record.tags.first { Text(tag) }
                                }
                                .font(.caption2)
                                .foregroundStyle(FloeTheme.primary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(filtered.count) 条提示词")
            }
        }
        .overlay {
            if store.isLoading && store.records.isEmpty {
                ProgressView("正在载入提示词库…")
            } else if !store.isLoading && filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "搜索标题、提示词、作者或标签")
        .navigationTitle("提示词库")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await store.load() }
                }
                .disabled(store.isLoading)
            }
        }
        .sheet(item: $detail) { record in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        promptCover(
                            record,
                            size: CGSize(width: 560, height: 280),
                            flexibleWidth: true
                        )
                        Text(record.title).font(.title2.bold())
                        if let description = record.description, !description.isEmpty {
                            Text(description).foregroundStyle(.secondary)
                        }
                        Text(record.prompt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        if !record.tags.isEmpty {
                            Text(record.tags.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(FloeTheme.primary)
                        }
                        if let model = record.imageModel, !model.isEmpty {
                            LabeledContent("参考模型", value: model)
                        }
                        if let source = record.sourceUrl, let url = URL(string: source) {
                            Link("查看原始来源", destination: url)
                        }
                    }
                    .padding()
                }
                .navigationTitle("提示词详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回") { detail = nil }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("复制", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = record.prompt
                        }
                        Button("插入画布", systemImage: "plus.rectangle.on.rectangle") {
                            detail = nil
                            onChoose(record)
                        }
                    }
                }
            }
        }
        .task { await store.load() }
        .onChange(of: selectedSource) { _, _ in
            if !selectedTag.isEmpty, !tags.contains(selectedTag) { selectedTag = "" }
        }
    }

    @ViewBuilder
    private func promptCover(
        _ record: CanvasPromptRecord,
        size: CGSize,
        flexibleWidth: Bool = false
    ) -> some View {
        let candidate = record.coverUrl ?? record.referenceImageUrls?.first
        AsyncImage(url: candidate.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Image(systemName: "photo").foregroundStyle(.secondary)
            case .empty:
                ProgressView()
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: flexibleWidth ? nil : size.width, height: size.height)
        .frame(maxWidth: flexibleWidth ? .infinity : nil)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct CanvasMediaGenerationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CanvasDocumentStore
    let sourceNodeIDs: Set<UUID>

    @State private var kind: MediaKind = .image
    @State private var prompt = ""
    @State private var selectedImageModelID: UUID?
    @State private var selectedVideoModelID: UUID?
    @State private var aspectRatio = "1:1"
    @State private var count = 1
    @State private var duration = 5
    @State private var quality = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var showsPromptLibrary = false

    private var videoModels: [ModelProfile] { environment.conversationCenter.videoModels }
    private var imageModels: [ModelProfile] {
        environment.conversationCenter.imageModels.filter {
            $0.capabilities.contains(.imageGeneration) || $0.capabilities.contains(.imageEditing)
        }
    }
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
                    Button("从提示词库选择", systemImage: "books.vertical") {
                        showsPromptLibrary = true
                    }
                    TextField("描述希望生成的内容", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                    Picker("画面比例", selection: $aspectRatio) {
                        ForEach(availableRatios, id: \.self) { Text($0).tag($0) }
                    }
                    if kind == .image {
                        Picker("图片模型", selection: $selectedImageModelID) {
                            ForEach(imageModels) { model in
                                Text(model.displayName).tag(Optional(model.id))
                            }
                        }
                        Stepper("生成数量：\(count)", value: $count, in: 1...4)
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

                let sources = store.generationSourceNodes(for: sourceNodeIDs)
                    .filter { $0.kind != .generationTask }
                if !sources.isEmpty {
                    Section("引用输入") {
                        ForEach(sources) { node in
                            Label(
                                node.text.isEmpty ? node.kind.rawValue : String(node.text.prefix(52)),
                                systemImage: sourceIcon(node.kind)
                            )
                        }
                        Text("会按画布连接顺序读取所选节点及其上游节点；原节点始终保留。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(kind == .image ? "生成图片" : "开始生成视频").frame(maxWidth: .infinity) }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || isSubmitting
                              || (kind == .image && selectedImageModelID == nil)
                              || (kind == .video && selectedVideoModelID == nil))
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
                selectedImageModelID = preferences.auxiliaryImageMode == .shared
                    ? preferences.sharedImageModelID
                    : preferences.imageGenerationModelID
                selectedVideoModelID = preferences.defaultVideoModelID ?? videoModels.first?.id
                restoreSelectionDefaults()
                normalizeOptions()
            }
            .onChange(of: selectedVideoModelID) { _, _ in normalizeOptions() }
            .onChange(of: kind) { _, _ in normalizeOptions() }
            .alert("无法生成", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("完成", role: .cancel) {} } message: { Text(error ?? "") }
            .sheet(isPresented: $showsPromptLibrary) {
                NavigationStack {
                    CanvasPromptLibraryView { record in
                        prompt = record.prompt
                        showsPromptLibrary = false
                    }
                }
            }
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
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedNodes = store.selectedDocument?.nodes.filter { sourceNodeIDs.contains($0.id) } ?? []
        let existingConfiguration = selectedNodes.first { $0.kind == .generationTask }
        let reusableEmptyMedia = selectedNodes.first {
            $0.asset == nil && (($0.kind == .image && kind == .image) || ($0.kind == .video && kind == .video))
        }
        let sources = store.generationSourceNodes(for: sourceNodeIDs)
            .filter { $0.kind != .generationTask && $0.id != reusableEmptyMedia?.id }
        let sourceIDs = sources.map(\.id)
        let contextLines = sources.compactMap { node -> String? in
            guard [.text, .stickyNote, .card].contains(node.kind) else { return nil }
            let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value == trimmedPrompt ? nil : value
        }
        let providerPrompt = contextLines.isEmpty
            ? trimmedPrompt
            : "\(trimmedPrompt)\n\n画布文字引用：\n\(contextLines.joined(separator: "\n"))"
        let resultPoint: CGPoint = if let reusableEmptyMedia {
            CGPoint(x: reusableEmptyMedia.x, y: reusableEmptyMedia.y)
        } else if let existingConfiguration {
            CGPoint(x: existingConfiguration.x + 420, y: existingConfiguration.y)
        } else if let source = sources.last {
            CGPoint(x: source.x + 840, y: source.y)
        } else {
            CGPoint(x: 780, y: 300)
        }
        let graphKind: CanvasGenerationGraphKind = kind == .image ? .image : .video
        let modelID = kind == .image ? selectedImageModelID : selectedVideoModelID
        let graphMetadata = [
            "generationModelID": modelID?.uuidString ?? "",
            "generationAspectRatio": aspectRatio,
            "generationQuality": quality,
            "generationCount": String(kind == .image ? count : 1),
            "generationDurationSeconds": kind == .video ? String(duration) : "",
            "generationState": "preparing"
        ]
        var configurationID: UUID?
        var resultNodeID: UUID?
        do {
            guard let graph = store.prepareGenerationGraph(CanvasGenerationGraphRequest(
                kind: graphKind, prompt: trimmedPrompt,
                sourceNodeIDs: sourceIDs,
                resultPosition: CanvasPoint(resultPoint),
                existingConfigurationNodeID: existingConfiguration?.id,
                reusableResultNodeID: reusableEmptyMedia?.id,
                metadata: graphMetadata
            )) else {
                throw FloeError.storageCorrupted("无法准备生成节点")
            }
            configurationID = graph.configurationNodeID
            resultNodeID = graph.resultNodeID
            if kind == .image {
                let ownerID = graph.configurationNodeID
                store.markGeneration(
                    nodeID: ownerID, kind: .image, prompt: trimmedPrompt,
                    modelID: selectedImageModelID, aspectRatio: aspectRatio,
                    quality: quality.isEmpty ? nil : quality, count: count,
                    sourceNodeIDs: graph.sourceNodeIDs, state: "running"
                )
                let referenceData = try sources.compactMap { try imageData(for: $0) }
                let assets = try await environment.mediaGenerationService.generateImages(
                    prompt: providerPrompt,
                    options: ImageGenerationOptions(
                        aspectRatio: aspectRatio,
                        quality: quality.isEmpty ? nil : quality,
                        count: count
                    ),
                    sourceImages: referenceData,
                    modelID: selectedImageModelID
                )
                guard !assets.isEmpty else {
                    throw RemoteImageError.invalidResponse("供应商没有返回图片。")
                }
                var resultIDs: [UUID] = []
                for (index, asset) in assets.enumerated() {
                    let id: UUID
                    if index == 0 {
                        store.attachAsset(asset, kind: .image, to: graph.resultNodeID)
                        id = graph.resultNodeID
                    } else {
                        id = store.addAsset(
                            asset, kind: .image,
                            at: CGPoint(x: resultPoint.x + Double(index) * 54,
                                        y: resultPoint.y + Double(index) * 42)
                        )
                        store.connect(graph.configurationNodeID, to: id, kind: .generatedFrom)
                    }
                    store.markGeneration(
                        nodeID: id, kind: .image, prompt: trimmedPrompt,
                        modelID: selectedImageModelID, aspectRatio: aspectRatio,
                        quality: quality.isEmpty ? nil : quality, count: assets.count,
                        sourceNodeIDs: graph.sourceNodeIDs, state: "ready"
                    )
                    store.updateNodeMetadata(id, values: [
                        "imageGroupPrimary": index == 0 ? "true" : "false"
                    ])
                    resultIDs.append(id)
                }
                if resultIDs.count > 1 {
                    store.group(Set(resultIDs))
                }
                store.updateNodeMetadata(ownerID, values: [
                    "generationState": "ready",
                    "generationResultNodeIDs": resultIDs.map(\.uuidString).joined(separator: ","),
                    "generationError": nil
                ])
            } else {
                let canvasID = store.project.id
                guard let documentID = store.selectedDocument?.id,
                      let model = selectedVideoModel else {
                    throw FloeError.invalidConfiguration("请选择视频模型。")
                }
                store.markGeneration(
                    nodeID: graph.resultNodeID, kind: .video, prompt: trimmedPrompt,
                    modelID: model.id, aspectRatio: aspectRatio,
                    quality: quality.isEmpty ? nil : quality, count: 1,
                    sourceNodeIDs: graph.sourceNodeIDs, state: "preparing"
                )
                let job = try await environment.mediaGenerationService.submitVideo(
                    modelID: model.id, canvasID: canvasID, documentID: documentID,
                    sourceNodeIDs: graph.sourceNodeIDs,
                    resultNodeID: graph.resultNodeID,
                    request: RemoteVideoRequest(
                        prompt: providerPrompt, modelRemoteID: model.remoteModelID,
                        options: VideoGenerationOptions(
                            aspectRatio: aspectRatio,
                            resolution: quality.isEmpty ? nil : quality,
                            durationSeconds: duration
                        )
                    )
                )
                store.setGenerationJob(job.id, for: graph.resultNodeID)
            }
            dismiss()
        } catch {
            for failedNodeID in [configurationID, resultNodeID].compactMap({ $0 }) {
                store.updateNodeMetadata(failedNodeID, values: [
                    "generationState": "failed",
                    "generationError": error.localizedDescription
                ])
            }
            self.error = error.localizedDescription
        }
    }

    private func restoreSelectionDefaults() {
        let selected = store.selectedDocument?.nodes.filter { sourceNodeIDs.contains($0.id) } ?? []
        guard let node = selected.first(where: {
            $0.kind == .generationTask || $0.metadata["generationPrompt"] != nil
        }) ?? selected.first else { return }
        if let storedKind = node.metadata["generationKind"].flatMap(MediaKind.init(rawValue:)) {
            kind = storedKind
        } else if node.kind == .video {
            kind = .video
        }
        let storedPrompt = node.metadata["generationPrompt"] ?? (node.kind == .text ? node.text : "")
        if !storedPrompt.isEmpty { prompt = storedPrompt }
        if let value = node.metadata["generationAspectRatio"], !value.isEmpty { aspectRatio = value }
        if let value = node.metadata["generationCount"].flatMap(Int.init) { count = min(4, max(1, value)) }
        if let value = node.metadata["generationQuality"] { quality = value }
        if let value = node.metadata["generationModelID"].flatMap(UUID.init(uuidString:)) {
            if kind == .image { selectedImageModelID = value }
            else { selectedVideoModelID = value }
        }
        if prompt.isEmpty {
            let upstreamText = store.generationSourceNodes(for: sourceNodeIDs)
                .filter { [.text, .stickyNote, .card].contains($0.kind) }
                .map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            prompt = upstreamText
        }
    }

    private func imageData(for node: FloeCanvasNode) throws -> Data? {
        guard node.kind == .image,
              let relativePath = node.asset?.localRelativePath,
              !relativePath.contains("..") else { return nil }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        let url = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func sourceIcon(_ kind: CanvasNodeKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .file: "doc"
        case .generationTask: "wand.and.stars"
        default: "text.alignleft"
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
                    ShareLink(item: item.url) {
                        Label("共享或保存文件", systemImage: "square.and.arrow.up")
                    }
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
