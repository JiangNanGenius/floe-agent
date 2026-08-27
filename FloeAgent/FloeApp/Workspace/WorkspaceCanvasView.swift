// FloeApp — Native workspace canvas.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeModels

private struct FloeCanvasPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

private struct FloeCanvasStroke: Codable, Hashable, Identifiable {
    var id = UUID()
    var points: [FloeCanvasPoint]
    var width: Double = 3
    var color: String = "primary"
}

private struct FloeCanvasNode: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var x: Double
    var y: Double
    var width: Double = 260
    var height: Double = 150
}

private struct FloeCanvasDocument: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var nodes: [FloeCanvasNode] = []
    var strokes: [FloeCanvasStroke] = []
    var createdAt = Date()
    var updatedAt = Date()
}

private struct FloeCanvasProject: Codable, Hashable {
    var schemaVersion = 1
    var workspaceID: UUID
    var name: String
    var documents: [FloeCanvasDocument]
    var selectedDocumentID: UUID
    var createdAt = Date()
    var updatedAt = Date()
}

@MainActor
private final class WorkspaceCanvasStore: ObservableObject {
    @Published private(set) var project: FloeCanvasProject
    @Published var saveError: String?

    private let fileURL: URL

    init(workspaceID: UUID, workspaceName: String) {
        let initial = FloeCanvasDocument(name: "画布 1")
        let fallback = FloeCanvasProject(
            workspaceID: workspaceID,
            name: workspaceName,
            documents: [initial],
            selectedDocumentID: initial.id
        )
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("Canvases", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            fileURL = directory.appendingPathComponent("\(workspaceID.uuidString).json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? decoder.decode(FloeCanvasProject.self, from: data),
               decoded.workspaceID == workspaceID,
               !decoded.documents.isEmpty {
                project = decoded
            } else {
                project = fallback
                persist()
            }
        } catch {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-canvas-\(workspaceID.uuidString).json")
            project = fallback
            saveError = error.localizedDescription
        }
    }

    var selectedDocument: FloeCanvasDocument? {
        project.documents.first { $0.id == project.selectedDocumentID }
            ?? project.documents.first
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
        project.documents.removeAll { $0.id == id }
        if project.selectedDocumentID == id {
            project.selectedDocumentID = project.documents[0].id
        }
        project.updatedAt = Date()
        persist()
    }

    func renameDocument(_ id: UUID, name: String) {
        mutateDocument(id) { $0.name = name }
    }

    func addNote(at point: CGPoint) {
        mutateSelectedDocument { document in
            document.nodes.append(FloeCanvasNode(
                text: "新建文本",
                x: point.x,
                y: point.y
            ))
        }
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

    func deleteNode(_ id: UUID) {
        mutateSelectedDocument { $0.nodes.removeAll { $0.id == id } }
    }

    func finishNodeMutation() {
        project.updatedAt = Date()
        persist()
    }

    func beginStroke(at point: CGPoint) -> UUID {
        let stroke = FloeCanvasStroke(points: [FloeCanvasPoint(point)])
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
        project.updatedAt = Date()
        persist()
    }

    func clearDrawing() {
        mutateSelectedDocument { $0.strokes.removeAll() }
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
        mutation(&project.documents[index])
        project.documents[index].updatedAt = Date()
        project.updatedAt = Date()
        if persistAfter { persist() }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(project).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct WorkspaceCanvasView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: WorkspaceCanvasStore
    @State private var selectedNodeID: UUID?
    @State private var mode: CanvasMode = .move
    @State private var scale = 1.0
    @State private var scaleStart = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var nodeDragOrigins: [UUID: CGPoint] = [:]
    @State private var activeStrokeID: UUID?
    @State private var showsDocuments = true

    private enum CanvasMode: String, CaseIterable, Identifiable {
        case move, draw
        var id: String { rawValue }
        var title: String { self == .move ? "选择与移动" : "画笔" }
        var icon: String { self == .move ? "arrow.up.and.down.and.arrow.left.and.right" : "pencil.tip" }
    }

    init(workspace: WorkspaceRecord) {
        _store = StateObject(wrappedValue: WorkspaceCanvasStore(
            workspaceID: workspace.id,
            workspaceName: workspace.name
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(showsDocuments ? .all : .detailOnly)) {
            documentSidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 300)
        } detail: {
            canvasDetail
        }
        .navigationSplitViewStyle(.balanced)
        .alert("画布无法保存", isPresented: Binding(
            get: { store.saveError != nil },
            set: { if !$0 { store.saveError = nil } }
        )) {
            Button("完成", role: .cancel) { store.saveError = nil }
        } message: {
            Text(store.saveError ?? "")
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
                grid(size: geometry.size)
                if let document = store.selectedDocument {
                    drawingLayer(document)
                    nodeLayer(document)
                }
                interactionLayer(size: geometry.size)
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .overlay(alignment: .topLeading) { modeControls(size: geometry.size) }
            .navigationTitle(store.selectedDocument?.name ?? "画布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsDocuments.toggle() } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("显示或隐藏画布列表")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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
                var path = Path()
                if let first = stroke.points.first {
                    path.move(to: screenPoint(first.cgPoint))
                    for point in stroke.points.dropFirst() {
                        path.addLine(to: screenPoint(point.cgPoint))
                    }
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

    private func nodeLayer(_ document: FloeCanvasDocument) -> some View {
        ForEach(document.nodes) { node in
            CanvasNoteView(
                text: Binding(
                    get: { node.text },
                    set: { store.updateNode(node.id, text: $0) }
                ),
                isSelected: selectedNodeID == node.id,
                onDelete: { store.deleteNode(node.id) }
            )
            .frame(width: node.width, height: node.height)
            .scaleEffect(scale)
            .position(screenPoint(CGPoint(x: node.x, y: node.y)))
            .onTapGesture { selectedNodeID = node.id }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard mode == .move else { return }
                        selectedNodeID = node.id
                        let origin = nodeDragOrigins[node.id]
                            ?? CGPoint(x: node.x, y: node.y)
                        nodeDragOrigins[node.id] = origin
                        store.updateNode(
                            node.id,
                            position: CGPoint(
                                x: origin.x + value.translation.width / scale,
                                y: origin.y + value.translation.height / scale
                            ),
                            persistAfter: false
                        )
                    }
                    .onEnded { _ in
                        guard mode == .move else { return }
                        nodeDragOrigins[node.id] = nil
                        store.finishNodeMutation()
                    }
            )
        }
    }

    private func interactionLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: mode == .draw ? 0 : 4)
                    .onChanged { value in
                        switch mode {
                        case .move:
                            pan = CGSize(
                                width: panStart.width + value.translation.width,
                                height: panStart.height + value.translation.height
                            )
                        case .draw:
                            let point = canvasPoint(value.location)
                            if let activeStrokeID {
                                store.appendPoint(point, to: activeStrokeID)
                            } else {
                                activeStrokeID = store.beginStroke(at: point)
                            }
                        }
                    }
                    .onEnded { _ in
                        if mode == .move {
                            panStart = pan
                        } else {
                            activeStrokeID = nil
                            store.finishStroke()
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
            .onTapGesture {
                if mode == .move { selectedNodeID = nil }
            }
    }

    private func modeControls(size: CGSize) -> some View {
        HStack(spacing: 8) {
            Picker("画布工具", selection: $mode) {
                ForEach(CanvasMode.allCases) { value in
                    Label(value.title, systemImage: value.icon).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Button {
                store.addNote(at: canvasPoint(CGPoint(x: size.width / 2, y: size.height / 2)))
            } label: {
                Label("添加文本", systemImage: "note.text.badge.plus")
            }
            .buttonStyle(.bordered)
            if mode == .draw {
                Button(role: .destructive) { store.clearDrawing() } label: {
                    Label("清除笔迹", systemImage: "eraser")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
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

    private func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + pan.width, y: point.y * scale + pan.height)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / scale, y: (point.y - pan.height) / scale)
    }
}

private struct CanvasNoteView: View {
    @Binding var text: String
    let isSelected: Bool
    let onDelete: () -> Void

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? FloeTheme.primary : .secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .contextMenu {
                Button("删除文本", role: .destructive, action: onDelete)
            }
    }
}
#endif
