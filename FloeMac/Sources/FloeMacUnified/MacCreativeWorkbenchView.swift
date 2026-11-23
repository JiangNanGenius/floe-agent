// SPDX-License-Identifier: MPL-2.0
import AppKit
import FloeCanvasTemplates
import FloeCanvasTemplatesUI
import FloeCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct MacCreativeWorkbenchView: View {
    @ObservedObject var library: MacCreativeLibrary
    @ObservedObject var images: MacImageGeneration
    @ObservedObject var videos: MacVideoGeneration
    let imageSettings: () -> Void
    let videoSettings: () -> Void
    /// Coordinator route: publishes the generated file through the existing
    /// pinned file import and returns to that task. Nil hides the button.
    var saveToTask: ((URL) async -> Bool)? = nil
    private enum Page: String { case canvas, image, video }
    private enum Editor: Identifiable {
        case rename, text(UUID?), title(UUID)
        var id: String { String(describing: self) }
    }
    private struct MediaToPlace {
        let url: URL
        let kind: CanvasNodeKind
    }
    /// Presentation route for the multi-track timeline editor.
    private struct TimelineEditorRoute: Identifiable {
        let id = UUID()
        var draft: MacTimelineDraft
    }
    @State private var page: Page = .canvas
    @State private var reference: URL?
    @State private var editor: Editor?
    @State private var draft = ""
    @State private var editingCanvas = false
    @State private var showsCanvasStart = false
    @State private var mediaToPlace: MediaToPlace?
    @State private var mediaEdit: MacMediaEditSession?
    @State private var timelineEditor: TimelineEditorRoute?
    @State private var trashID: UUID?
    @State private var query = ""
    @State private var dragID: UUID?
    @State private var offset: CGSize = .zero
    @State private var connect = MacCanvasConnectSession()

    var body: some View {
        VStack(spacing: 0) {
            pagePicker
            Divider()
            switch page {
            case .canvas:
                if editingCanvas, library.selected != nil {
                    VStack(spacing: 0) { boards }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard library.selected != nil, !library.isTransferring else { return false }
                        var added = false
                        for url in urls where url.isFileURL {
                            guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
                            let kind: CanvasNodeKind? = type.conforms(to: .image) ? .image
                                : type.conforms(to: .movie) ? .video
                                : type.conforms(to: .audio) ? .audio : nil
                            guard let kind else { continue }
                            do {
                                try library.addMedia(url, kind: kind,
                                                     title: url.deletingPathExtension().lastPathComponent)
                                added = true
                            } catch { library.error = error.localizedDescription }
                        }
                        return added
                    }
                    #if FLOE_MAC_HOST_SMOKE
                    .onAppear { library.smokeCanvasEditorOpen = true }
                    .onDisappear { library.smokeCanvasEditorOpen = false }
                    #endif
                } else {
                    canvasLibrary
                }
            case .image:
                MacImageWorkbenchView(images: images, openSettings: imageSettings, attachToTask: nil,
                    saveToTask: saveToTask,
                    addToCanvas: { url in routeToCanvas(url, kind: .image) },
                    initialReference: reference)
            case .video:
                MacVideoWorkbenchView(videos: videos, openSettings: videoSettings,
                    saveToTask: saveToTask,
                    addToCanvas: { url in routeToCanvas(url, kind: .video) },
                    initialReference: reference)
            }
        }
        .onChange(of: page) { _, destination in if destination == .canvas { reference = nil } }
        .confirmationDialog("mac.creative.trashPrompt", isPresented: Binding(get: { trashID != nil },
            set: { if !$0 { trashID = nil } }), presenting: trashID) { id in
            Button("mac.creative.trash", role: .destructive) {
                guard library.selectedID == id else { return }
                Task {
                    do { try await library.trashSelected(); editingCanvas = false }
                    catch { library.error = error.localizedDescription }
                }
            }
            Button("mac.creative.cancel", role: .cancel) {}
        }
        .sheet(item: $editor) { edit in
            VStack(alignment: .leading, spacing: 14) {
                Text(editTitle(edit)).font(.headline)
                if case .text = edit {
                    TextEditor(text: $draft).font(.body).frame(width: 320, height: 110)
                } else { TextField("mac.creative.name", text: $draft).frame(width: 300) }
                HStack {
                    Spacer()
                    Button("mac.creative.cancel", role: .cancel) { editor = nil }.keyboardShortcut(.cancelAction)
                    Button("mac.creative.save") {
                        perform {
                            switch edit {
                            case .rename: try library.rename(draft)
                            case .text(let id):
                                if let id { try library.setText(draft, id: id) } else { try library.addText(draft) }
                            case .title(let id): try library.setTitle(draft, id: id)
                            }
                            editor = nil
                        }
                    }.keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
        .sheet(item: $mediaEdit) { session in
            MacMediaEditorView(session: session)
        }
        .sheet(item: $timelineEditor) { route in
            Group {
                if let store = library.timelineDraftStore {
                    MacTimelineEditorView(
                        store: store,
                        draft: route.draft,
                        saveToTask: saveToTask,
                        addToCanvas: { url in routeToCanvas(url, kind: .video) },
                        onDraftsChanged: {})
                } else {
                    ContentUnavailableView(MacCanvasText.routeFailed, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .sheet(isPresented: $showsCanvasStart) {
            VStack(spacing: 0) {
                HStack {
                    Text(FloeL10n.isChinese ? "新建画布" : "New Canvas").font(.headline)
                    Spacer()
                    Button("mac.creative.cancel") { showsCanvasStart = false }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("canvas.start.cancel")
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { library.smokeCanvasTemplateCloseFrame = $0 })
                        #endif
                }
                .padding(12)
                Divider()
                CanvasTemplatePicker(scenarios: BuiltInCanvasTemplates.all.filter { [.research, .ideas].contains($0.category) },
                                     chinese: FloeL10n.isChinese, onGoal: { goal, template in
                    createCanvas(template: template, goal: goal)
                }) { template in
                    createCanvas(template: template, goal: nil)
                }
            }
            .frame(minWidth: 560, idealWidth: 700, minHeight: 430, idealHeight: 560)
        }
        .alert("mac.creative.error", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(verbatim: library.error ?? "") }
    }

    private var pagePicker: some View {
        HStack {
            Picker("mac.creative.title", selection: $page) {
                Text("mac.creative.canvas").tag(Page.canvas)
                Text("mac.settings.images").tag(Page.image)
                Text("mac.creative.video").tag(Page.video)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { library.smokeTabFrame = $0 })
            .onAppear { library.smokeTab = page.rawValue }
            .onChange(of: page) { _, tab in library.smokeTab = tab.rawValue }
            #endif
            Spacer()
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func editTitle(_ edit: Editor) -> LocalizedStringKey {
        switch edit {
        case .rename: "mac.creative.rename"
        case .text: "mac.creative.text"
        case .title: "mac.creative.rename"
        }
    }

    @ViewBuilder private var boards: some View {
        boardToolbar
        Divider()
        if let document = library.page {
            preservedInkBanner(document)
            if connect.isActive {
                connectBanner
            }
            if document.nodes.isEmpty && document.strokes.isEmpty {
                ContentUnavailableView("mac.creative.blank", systemImage: "rectangle.dashed", description: Text("mac.creative.blankHint"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                boardCanvas(document)
            }
        }
    }

    private var canvasLibrary: some View {
        let visible = library.projects.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || $0.documents.contains { page in page.nodes.contains { $0.text.localizedStandardContains(query) } }
        }
        return VStack(spacing: 0) {
            HStack {
                TextField("mac.creative.find", text: $query)
                Button("mac.creative.importCanvas", systemImage: "square.and.arrow.down") { transfer(export: false) }
                if library.isTransferring { ProgressView().controlSize(.small) }
            }.padding(12)
            Divider()
            List {
                if mediaToPlace != nil {
                    Section {
                        Text(FloeL10n.isChinese ? "选择画布来放置生成结果。" : "Choose a canvas for the generated result.")
                        Button("mac.creative.cancel") { mediaToPlace = nil }
                    }
                }
                Section(FloeL10n.isChinese ? "快速开始" : "Quick Start") {
                    FloeCanvasStartRow { showsCanvasStart = true }
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { library.smokeCanvasCreateFrame = $0 })
                        #endif
                }
                Section(FloeL10n.isChinese ? "画布" : "Canvases") {
                    ForEach(visible) { project in
                        Button { openCanvas(project.id) } label: {
                            FloeCanvasLibraryRow(title: project.name) {
                                Text(project.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("canvas.home.open." + project.id.uuidString)
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { library.smokeCanvasFrames[project.id] = $0 })
                        #endif
                    }
                    if visible.isEmpty {
                        Text(query.isEmpty ? (FloeL10n.isChinese ? "这里还没有画布" : "No canvases yet")
                             : (FloeL10n.isChinese ? "没有匹配的画布" : "No matching canvases"))
                            .foregroundStyle(.secondary)
                    }
                }
            }.listStyle(.inset)
        }.disabled(library.isTransferring)
    }

    // MARK: - Board toolbar

    private var boardToolbar: some View {
        HStack {
            Button {
                editingCanvas = false
                connect.cancel()
            } label: {
                Label(FloeL10n.isChinese ? "画布列表" : "Canvases", systemImage: "chevron.left")
            }
            .accessibilityIdentifier("canvas.editor.library")
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { library.smokeCanvasLibraryBackFrame = $0 })
            #endif
            Text(library.selected?.name ?? "").lineLimit(1)
            if library.selected != nil {
                pagePickerInline
                Button { present(.text(nil)) } label: { Label("mac.creative.text", systemImage: "textformat") }
                mediaMenu
                undoButton
                preservedBadge
                Menu {
                    Button("mac.creative.rename") { present(.rename, library.selected?.name ?? "") }
                    Button("mac.creative.export") { transfer(export: true) }
                    Button("mac.creative.trash", role: .destructive) { trashID = library.selectedID }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.accessibilityLabel(FloeL10n.isChinese ? "画布操作" : "Canvas Actions")
            }
            Spacer(minLength: 0)
            if library.isTransferring { ProgressView().controlSize(.small) }
        }.disabled(library.isTransferring).padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var pagePickerInline: some View {
        if let project = library.selected, project.documents.count > 1 {
            Picker("mac.creative.page", selection: Binding(get: { project.selectedDocumentID },
                set: { id in perform { try library.selectDocument(id) } })) {
                ForEach(project.documents) { doc in Text(verbatim: doc.name).tag(doc.id) }
            }.labelsHidden().frame(maxWidth: 160)
        }
    }

    private var mediaMenu: some View {
        Menu {
            Button("mac.creative.import") { importFile() }
            Divider()
            Button(MacCanvasText.newTimelineDraft, systemImage: "timeline.selection") { createTimelineDraft() }
            let drafts = library.timelineDrafts()
            if !drafts.isEmpty {
                Section(MacCanvasText.timelineDraftsSection) {
                    ForEach(drafts) { item in
                        Button(item.name) { openTimelineDraft(item) }
                    }
                }
            } else {
                Button(MacCanvasText.openTimelineDraft, systemImage: "folder") { openTimelineDraftPicker() }
            }
            if !images.history.isEmpty {
                Section("mac.settings.images") {
                    ForEach(images.history) { item in
                        Button(item.prompt) { add(images.imageURL(for: item), kind: .image, title: item.prompt) }
                    }
                }
            }
            if videos.history.contains(where: { videos.videoURL(for: $0) != nil }) {
                Section("mac.creative.video") {
                    ForEach(videos.history) { item in
                        if let file = videos.videoURL(for: item) {
                            Button(item.prompt) { add(file, kind: .video, title: item.prompt) }
                        }
                    }
                }
            }
        } label: { Label("mac.creative.media", systemImage: "photo.on.rectangle") }
    }

    // MARK: Timeline drafts

    /// Creates a fresh draft with one empty visual track, persists it, and
    /// opens the timeline editor on it.
    private func createTimelineDraft() {
        do {
            var value = try MacTimelineDraft(name: FloeL10n.isChinese ? "未命名时间线" : "Untitled Timeline")
            _ = try value.addTrack(.visual)
            try library.saveTimelineDraft(value)
            timelineEditor = TimelineEditorRoute(draft: value)
        } catch {
            library.error = error.localizedDescription
        }
    }

    private func openTimelineDraft(_ value: MacTimelineDraft) {
        timelineEditor = TimelineEditorRoute(draft: value)
    }

    private func openTimelineDraftPicker() {
        // No drafts yet: create the first one, which is the only action the
        // picker could offer anyway.
        createTimelineDraft()
    }

    /// Opens a timeline editor preloaded with this node as its first clip.
    /// The draft is persisted immediately, so closing the editor keeps the
    /// imported media on the timeline for later editing.
    private func openNodeInTimeline(node: CanvasNode, url: URL) {
        Task { await openNodeInTimeline(node: node, url: url) }
    }

    private func openNodeInTimeline(node: CanvasNode, url: URL) async {
        do {
            let title = node.title ?? url.deletingPathExtension().lastPathComponent
            var value = try MacTimelineDraft(name: title)
            let track = try value.addTrack(.visual)
            let info = try await MacTimelineAssetProber.probe(url)
            let duration = info.isStillImage ? 5 : max(info.duration, 0.1)
            let clip = try MacTimelineClip.media(
                sourceURL: url, title: title, timelineStart: 0, duration: duration)
            try value.addClip(clip, toTrack: track.id)
            try library.saveTimelineDraft(value)
            timelineEditor = TimelineEditorRoute(draft: value)
        } catch {
            library.error = error.localizedDescription
        }
    }

    private var undoButton: some View {
        Button { perform { try library.undo() } } label: {
            Image(systemName: "arrow.uturn.backward")
        }.help(MacCanvasText.undo)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!library.canUndo)
    }

    @ViewBuilder private var preservedBadge: some View {
        if library.hasPreservedContent {
            Label(MacCanvasText.readonlyKind, systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: - Board banners

    @ViewBuilder private func preservedInkBanner(_ document: CanvasDocument) -> some View {
        if document.pencilDrawingData != nil || !document.strokes.isEmpty {
            HStack(spacing: 10) {
                if document.pencilDrawingData != nil {
                    Label(MacCanvasText.preservedPencil, systemImage: "pencil.tip")
                }
                if !document.strokes.isEmpty {
                    Label(MacCanvasText.preservedStrokes(document.strokes.count), systemImage: "scribble")
                }
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 4)
            Divider()
        }
    }

    private var connectBanner: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(MacCanvasText.connectBanner).font(.callout).lineLimit(2)
                Spacer()
                Button(MacCanvasText.connectCancel) { connect.cancel() }
            }.padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: - Board canvas

    private func boardCanvas(_ document: CanvasDocument) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    inkLayer(document)
                    connectionLayer(document)
                    nodesLayer(document)
                    connectionBadges(document)
                }
                .frame(width: boardWidth(document, in: geo), height: boardHeight(document, in: geo), alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if connect.isActive { connect.cancel() }
                }
            }
            .onExitCommand { connect.cancel() }
        }
    }

    private func boardWidth(_ document: CanvasDocument, in geo: GeometryProxy) -> CGFloat {
        max(geo.size.width, document.nodes.map { $0.position.x + $0.size.width + 32 }.max() ?? 0)
    }

    private func boardHeight(_ document: CanvasDocument, in geo: GeometryProxy) -> CGFloat {
        max(geo.size.height, document.nodes.map { $0.position.y + $0.size.height + 32 }.max() ?? 0)
    }

    private func nodesLayer(_ document: CanvasDocument) -> some View {
        ForEach(document.nodes) { node in
            tile(node)
                .frame(width: node.size.width, height: node.size.height)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(nodeBorder(node).stroke(nodeBorderColor(node), style: nodeBorderStyle(node)))
                .offset(x: node.position.x + (dragID == node.id ? offset.width : 0),
                        y: node.position.y + (dragID == node.id ? offset.height : 0))
                .zIndex(Double(node.zIndex))
        }
    }

    private func nodeBorder(_ node: CanvasNode) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: 8)
    }

    private func nodeBorderColor(_ node: CanvasNode) -> Color {
        MacCanvasBackupProjection.isEditable(node) ? Color(nsColor: .separatorColor) : Color.secondary.opacity(0.45)
    }

    private func nodeBorderStyle(_ node: CanvasNode) -> StrokeStyle {
        if MacCanvasBackupProjection.isEditable(node) {
            return StrokeStyle()
        }
        return StrokeStyle(dash: [5, 3])
    }

    /// Read-only ink: freehand strokes render as fixed polylines; PencilKit
    /// bytes stay opaque and are represented by a badge only.
    @ViewBuilder private func inkLayer(_ document: CanvasDocument) -> some View {
        Canvas { context, _ in
            for stroke in document.strokes {
                guard stroke.points.count > 1 else { continue }
                var path = Path()
                path.move(to: CGPoint(x: stroke.points[0].x, y: stroke.points[0].y))
                for point in stroke.points.dropFirst() {
                    guard point.x.isFinite, point.y.isFinite else { continue }
                    path.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                context.stroke(path, with: .color(Self.inkColor(stroke.color)),
                               style: StrokeStyle(lineWidth: max(1, stroke.width), lineCap: .round, lineJoin: .round))
            }
        }
    }

    private static func inkColor(_ raw: String) -> Color {
        switch raw {
        case "primary": return .primary
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "black": return .black
        case "white": return .white
        default:
            if raw.hasPrefix("#"), raw.count == 7 {
                var value: UInt64 = 0
                if Scanner(string: String(raw.dropFirst())).scanHexInt64(&value) {
                    return Color(red: Double((value >> 16) & 0xFF) / 255,
                                 green: Double((value >> 8) & 0xFF) / 255,
                                 blue: Double(value & 0xFF) / 255)
                }
            }
            return .secondary
        }
    }

    private func nodeCenter(_ node: CanvasNode) -> CGPoint? {
        guard node.position.x.isFinite, node.position.y.isFinite else { return nil }
        return CGPoint(x: node.position.x + node.size.width / 2, y: node.position.y + node.size.height / 2)
    }

    @ViewBuilder private func connectionLayer(_ document: CanvasDocument) -> some View {
        Canvas { context, _ in
            let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
            for connection in document.connections {
                guard let source = nodes[connection.sourceNodeID],
                      let destination = nodes[connection.destinationNodeID],
                      let start = nodeCenter(source),
                      let end = nodeCenter(destination) else { continue }
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                Self.drawArrowhead(context: context, from: start, to: end)
            }
        }
        .allowsHitTesting(false)
    }

    private static func drawArrowhead(context: GraphicsContext, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 9
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
        context.stroke(head, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    @ViewBuilder private func connectionBadges(_ document: CanvasDocument) -> some View {
        let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        ForEach(document.connections) { connection in
            if let source = nodes[connection.sourceNodeID], let destination = nodes[connection.destinationNodeID],
               let start = nodeCenter(source), let end = nodeCenter(destination) {
                connectionBadge(connection)
                    .offset(x: (start.x + end.x) / 2 - 8, y: (start.y + end.y) / 2 - 8)
            }
        }
    }

    private func connectionBadge(_ connection: CanvasConnection) -> some View {
        Button { perform { try library.removeConnection(connection.id) } } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }.buttonStyle(.plain)
            .help(MacCanvasText.removeConnection)
    }

    // MARK: - Node tile

    private func tile(_ node: CanvasNode) -> some View {
        let capability = MacCanvasBackupProjection.capability(of: node)
        let editable = capability == .editable
        return VStack(alignment: .leading, spacing: 5) {
            tileHeader(node, capability: capability, editable: editable)
            tileBody(node, capability: capability)
        }.padding(10).contentShape(Rectangle())
            .opacity(editable ? 1 : 0.82)
            .onTapGesture { handleTileTap(node) }
            .gesture(editable ? nodeDrag(node) : nil)
    }

    private func tileHeader(_ node: CanvasNode, capability: MacCanvasBackupProjection.NodeCapability, editable: Bool) -> some View {
        HStack {
            Image(systemName: Self.kindIcon(node.kind))
            Text(verbatim: node.title ?? String(localized: "mac.creative.text")).lineLimit(1)
            if !editable {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .help(MacCanvasBackupProjection.readonlyBadge(capability))
            }
            Spacer(minLength: 0)
            if connect.isActive {
                // While connecting, the whole tile is one tap target; the
                // per-tile menu stays out of the way.
                Image(systemName: "link").foregroundStyle(.secondary)
            } else {
                tileMenu(node, editable: editable)
            }
        }.font(.caption)
    }

    private func tileMenu(_ node: CanvasNode, editable: Bool) -> some View {
        Menu {
            Button(MacCanvasText.connectFrom) { connect.begin(from: node.id) }
            if editable {
                // Text-bearing content nodes share the text editor.
                if MacCreativeLibrary.textEditableKinds.contains(node.kind) {
                    Button("mac.creative.edit") { present(.text(node.id), node.text) }
                }
                if node.kind == .shape {
                    Menu(MacCanvasText.shapeMenu) {
                        ForEach(CanvasShapeKind.allCases, id: \.self) { shape in
                            let current = node.shape == shape
                            Button {
                                perform { try library.setShape(shape, id: node.id) }
                            } label: {
                                HStack {
                                    Text(MacCanvasText.shapeName(shape))
                                    if current { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                Button(MacCanvasText.renameNode) { present(.title(node.id), node.title ?? "") }
                if (node.kind == .image || node.kind == .video), let url = library.assetURL(node) {
                    Button(node.kind == .image ? MacMediaEditStrings.editImage : MacMediaEditStrings.editVideo) {
                        openMediaEditor(node: node, url: url)
                    }
                    .accessibilityIdentifier("mac.canvas.editNode")
                }
                if (node.kind == .image || node.kind == .video), let url = library.assetURL(node) {
                    Button(MacCanvasText.editInTimeline) { openNodeInTimeline(node: node, url: url) }
                }
                if node.kind == .image, let url = library.assetURL(node) {
                    if images.maximumReferenceImages > 0 {
                        Button("mac.creative.useImageReference") { reference = url; page = .image }
                    }
                    if MacVideoWorkbenchView.acceptsReference(videos.configuration) {
                        Button("mac.creative.useFirstFrame") { reference = url; page = .video }
                    }
                }
                if let url = library.assetURL(node) { Button("mac.creative.open") { NSWorkspace.shared.open(url) } }
                Button("mac.creative.remove", role: .destructive) { perform { try library.remove(node.id) } }
            } else if let url = library.assetURL(node) {
                // Read-only tiles keep a safe open action; every mutating
                // action stays with the iPad editor.
                Button("mac.creative.open") { NSWorkspace.shared.open(url) }
            }
        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
    }

    private func tileBody(_ node: CanvasNode, capability: MacCanvasBackupProjection.NodeCapability) -> some View {
        Group {
            if node.kind == .image, let url = library.assetURL(node), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
            } else if (node.kind == .video || node.kind == .audio), let file = library.assetURL(node) {
                Button { NSWorkspace.shared.open(file) } label: {
                    Image(systemName: node.kind == .video ? "play.rectangle" : "waveform.circle")
                        .font(.largeTitle)
                }.buttonStyle(.plain)
            } else if node.kind == .file, let file = library.assetURL(node) {
                VStack(spacing: 4) {
                    Image(systemName: "doc").font(.title2)
                    Text(verbatim: file.lastPathComponent)
                        .font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
            } else if node.kind == .shape {
                shapeBody(node)
            } else if MacCreativeLibrary.textEditableKinds.contains(node.kind) {
                Text(verbatim: node.text).lineLimit(5)
            } else {
                // Read-only representation of preserved content.
                VStack(spacing: 4) {
                    Image(systemName: Self.preservedIcon(node))
                        .font(.title2).foregroundStyle(.secondary)
                    Text(MacCanvasBackupProjection.readonlyBadge(capability))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shapeBody(_ node: CanvasNode) -> some View {
        let shape = node.shape ?? .roundedRectangle
        let color = node.metadata["shapeFill"].flatMap(Self.rgbColor) ?? Color.accentColor
        return ZStack {
            switch shape {
            case .rectangle:
                Rectangle().fill(color.opacity(0.25))
            case .roundedRectangle:
                RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.25))
            case .ellipse:
                Ellipse().fill(color.opacity(0.25))
            case .diamond:
                DiamondShape().fill(color.opacity(0.25))
            case .triangle:
                TriangleShape().fill(color.opacity(0.25))
            }
            if !node.text.isEmpty {
                Text(verbatim: node.text).lineLimit(4).padding(6)
            }
        }
        .padding(4)
    }

    private struct DiamondShape: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                p.closeSubpath()
            }
        }
    }

    private struct TriangleShape: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }

    private static func rgbColor(_ hex: String) -> Color? {
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private static func kindIcon(_ kind: CanvasNodeKind) -> String {
        switch kind {
        case .text: return "textformat"
        case .stickyNote: return "note.text"
        case .card: return "rectangle.on.rectangle"
        case .shape: return "square.on.circle"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .file: return "doc"
        case .group: return "folder"
        case .generationTask: return "sparkles"
        case .scene3D: return "cube"
        }
    }

    private func nodeDrag(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { dragID = node.id; offset = $0.translation }
            .onEnded { value in
                dragID = nil; offset = .zero
                perform { try library.move(node.id, x: node.position.x + value.translation.width, y: node.position.y + value.translation.height) }
            }
    }

    private func handleTileTap(_ node: CanvasNode) {
        guard connect.isActive else { return }
        guard let source = connect.complete(to: node.id) else { return }
        perform { _ = try library.addConnection(from: source, to: node.id) }
    }

    private static func preservedIcon(_ node: CanvasNode) -> String {
        switch node.kind {
        case .scene3D: return "cube"
        case .audio: return "waveform"
        case .file: return "doc"
        case .shape: return "square.on.circle"
        case .group: return "folder"
        case .generationTask: return "sparkles"
        case .stickyNote, .card: return "rectangle.on.rectangle.angled"
        default: return "lock.fill"
        }
    }

    // MARK: - Actions

    private func present(_ edit: Editor, _ value: String = "") { draft = value; editor = edit }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { library.error = error.localizedDescription }
    }
    private func add(_ file: URL, kind: CanvasNodeKind, title: String) { perform { try library.addMedia(file, kind: kind, title: title) } }

    /// Opens the reusable media editor on a canvas node. The owning canvas
    /// is captured now: an edited result may only join that same canvas
    /// (as a new node; the source node and its asset are never mutated),
    /// and the task route captured by this view stays the task owner from
    /// the moment editing started.
    private func openMediaEditor(node: CanvasNode, url: URL) {
        let ownerCanvasID = library.selectedID
        let nodeKind = node.kind
        let title = node.title ?? url.deletingPathExtension().lastPathComponent
        mediaEdit = MacMediaEditSession(
            source: .init(url: url, kind: nodeKind == .video ? .video : .image, title: title),
            saveToTask: saveToTask,
            addToCanvas: { output in
                guard library.selectedID == ownerCanvasID else {
                    library.error = MacCanvasText.routeFailed
                    return
                }
                add(output, kind: nodeKind, title: output.deletingPathExtension().lastPathComponent)
            })
    }

    private func routeToCanvas(_ url: URL, kind: CanvasNodeKind) {
        mediaToPlace = MediaToPlace(url: url, kind: kind)
        if editingCanvas, let id = library.selectedID { openCanvas(id) }
        else {
            query = ""
            page = .canvas
        }
    }

    private func createCanvas(template: CanvasTemplate?, goal: String?) {
        perform {
            try library.create(template: template, goal: goal, chinese: FloeL10n.isChinese)
            showsCanvasStart = false
            if let id = library.selectedID { openCanvas(id) }
        }
    }

    private func openCanvas(_ id: UUID) {
        if library.selectedID != id { library.selectedID = id }
        connect.cancel()
        editingCanvas = true
        page = .canvas
        if let media = mediaToPlace {
            perform {
                try library.addMedia(media.url, kind: media.kind, title: media.url.deletingPathExtension().lastPathComponent)
                mediaToPlace = nil
            }
        }
    }

    private func transfer(export: Bool) {
        let panel: NSSavePanel
        if export {
            panel = NSSavePanel()
            panel.nameFieldStringValue = (library.selected?.name ?? "Canvas").replacingOccurrences(of: "/", with: "-") + ".floeCanvas"
        } else { panel = NSOpenPanel() }
        if let type = UTType(filenameExtension: "floeCanvas") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                if export { try await library.exportSelected(to: url) }
                else {
                    try await library.importCanvas(from: url)
                    if let id = library.selectedID { openCanvas(id) }
                }
            } catch { library.error = error.localizedDescription }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audio]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let type = UTType(filenameExtension: file.pathExtension)
        let kind: CanvasNodeKind = type?.conforms(to: .movie) == true ? .video
            : type?.conforms(to: .audio) == true ? .audio : .image
        add(file, kind: kind, title: file.deletingPathExtension().lastPathComponent)
    }
}
