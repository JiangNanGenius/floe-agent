// SPDX-License-Identifier: MPL-2.0
import AppKit
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
    private enum Page: String { case canvas, image, video }
    private enum Editor: Identifiable {
        case create, rename, text(UUID?)
        var id: String { String(describing: self) }
    }
    @State private var page: Page = .canvas
    @State private var reference: URL?
    @State private var editor: Editor?
    @State private var draft = ""
    @State private var showLibrary = false
    @State private var trashID: UUID?
    @State private var query = ""
    @State private var dragID: UUID?
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
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
            Divider()
            switch page {
            case .canvas:
                VStack(spacing: 0) { boards }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard library.selected != nil, !library.isTransferring else { return false }
                        var added = false
                        for url in urls where url.isFileURL {
                            guard let type = UTType(filenameExtension: url.pathExtension),
                                  type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
                            do {
                                try library.addMedia(url, kind: type.conforms(to: .image) ? .image : .video,
                                                     title: url.deletingPathExtension().lastPathComponent)
                                added = true
                            } catch { library.error = error.localizedDescription }
                        }
                        return added
                    }
            case .image: MacImageWorkbenchView(images: images, openSettings: imageSettings, attachToTask: nil, initialReference: reference)
            case .video: MacVideoWorkbenchView(videos: videos, openSettings: videoSettings, initialReference: reference)
            }
        }
        .onChange(of: page) { _, destination in if destination == .canvas { reference = nil } }
        .confirmationDialog("mac.creative.trashPrompt", isPresented: Binding(get: { trashID != nil },
            set: { if !$0 { trashID = nil } }), presenting: trashID) { id in
            Button("mac.creative.trash", role: .destructive) {
                guard library.selectedID == id else { return }
                Task { do { try await library.trashSelected() } catch { library.error = error.localizedDescription } }
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
                            case .create: try library.create(name: draft)
                            case .rename: try library.rename(draft)
                            case .text(let id):
                                if let id { try library.setText(draft, id: id) } else { try library.addText(draft) }
                            }
                            editor = nil
                        }
                    }.keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
        .alert("mac.creative.error", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(verbatim: library.error ?? "") }
    }

    private func editTitle(_ edit: Editor) -> LocalizedStringKey {
        switch edit { case .create: "mac.creative.new"; case .rename: "mac.creative.rename"; case .text: "mac.creative.text" }
    }

    @ViewBuilder private var boards: some View {
        HStack {
            Button { query = ""; showLibrary.toggle() } label: {
                Label(library.selected?.name ?? String(localized: "mac.creative.canvas"), systemImage: "rectangle.on.rectangle")
                    .lineLimit(1)
            }.popover(isPresented: $showLibrary, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("mac.creative.find", text: $query)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(library.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { project in
                                Button {
                                    library.selectedID = project.id
                                    showLibrary = false
                                } label: {
                                    HStack {
                                        Image(systemName: project.id == library.selectedID ? "checkmark" : "rectangle")
                                        Text(verbatim: project.name).lineLimit(1)
                                        Spacer()
                                    }.padding(4).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 185)
                    Divider()
                    Button("mac.creative.new") { showLibrary = false; present(.create) }
                    Button("mac.creative.importCanvas") { showLibrary = false; transfer(export: false) }
                    if library.selected != nil {
                        Button("mac.creative.rename") { showLibrary = false; present(.rename, library.selected?.name ?? "") }
                        Button("mac.creative.export") { showLibrary = false; transfer(export: true) }
                        Button("mac.creative.trash", role: .destructive) { showLibrary = false; trashID = library.selectedID }

                    }
                }.padding(12).frame(width: 250)
            }
            if library.selected != nil {
                if let project = library.selected, project.documents.count > 1 {
                    Picker("mac.creative.page", selection: Binding(get: { project.selectedDocumentID },
                        set: { id in perform { try library.selectDocument(id) } })) {
                        ForEach(project.documents) { doc in Text(verbatim: doc.name).tag(doc.id) }
                    }.labelsHidden().frame(maxWidth: 160)
                }
                Button { present(.text(nil)) } label: { Label("mac.creative.text", systemImage: "textformat") }
                Menu {
                    Button("mac.creative.import") { importFile() }
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
            Spacer(minLength: 0)
            if library.isTransferring { ProgressView().controlSize(.small) }
        }.disabled(library.isTransferring).padding(.horizontal, 16).padding(.vertical, 8)
        Divider()
        if let document = library.page {
            if document.nodes.isEmpty {
                ContentUnavailableView("mac.creative.blank", systemImage: "rectangle.dashed", description: Text("mac.creative.blankHint"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            ForEach(document.nodes) { node in
                                tile(node)
                                    .frame(width: node.size.width, height: node.size.height)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                                    .offset(x: node.position.x + (dragID == node.id ? offset.width : 0),
                                            y: node.position.y + (dragID == node.id ? offset.height : 0))
                                    .zIndex(Double(node.zIndex))
                            }
                        }.frame(width: max(geo.size.width, document.nodes.map { $0.position.x + $0.size.width + 32 }.max() ?? 0),
                                height: max(geo.size.height, document.nodes.map { $0.position.y + $0.size.height + 32 }.max() ?? 0),
                                alignment: .topLeading)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("mac.creative.canvas", systemImage: "rectangle.on.rectangle")
            } actions: {
                Button("mac.creative.new") { present(.create) }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tile(_ node: CanvasNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: node.kind == .text ? "textformat" : node.kind == .image ? "photo" : "film")
                Text(verbatim: node.title ?? String(localized: "mac.creative.text")).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    if node.kind == .image, let url = library.assetURL(node) {
                        if images.maximumReferenceImages > 0 {
                            Button("mac.creative.useImageReference") { reference = url; page = .image }
                        }
                        if MacVideoWorkbenchView.acceptsReference(videos.configuration) {
                            Button("mac.creative.useFirstFrame") { reference = url; page = .video }
                        }
                    }
                    if node.kind == .text { Button("mac.creative.edit") { present(.text(node.id), node.text) } }
                    if let url = library.assetURL(node) { Button("mac.creative.open") { NSWorkspace.shared.open(url) } }
                    Button("mac.creative.remove", role: .destructive) { perform { try library.remove(node.id) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.font(.caption)
            Group {
                if node.kind == .image, let url = library.assetURL(node), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400,
                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else if node.kind == .video, let file = library.assetURL(node) {
                    Button { NSWorkspace.shared.open(file) } label: { Image(systemName: "play.rectangle").font(.largeTitle) }.buttonStyle(.plain)
                } else { Text(verbatim: node.text).lineLimit(5) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(10).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { dragID = node.id; offset = $0.translation }
            .onEnded { value in
                dragID = nil; offset = .zero
                perform { try library.move(node.id, x: node.position.x + value.translation.width, y: node.position.y + value.translation.height) }
            })
    }

    private func present(_ edit: Editor, _ value: String = "") { draft = value; editor = edit }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { library.error = error.localizedDescription }
    }
    private func add(_ file: URL, kind: CanvasNodeKind, title: String) { perform { try library.addMedia(file, kind: kind, title: title) } }
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
                else { try await library.importCanvas(from: url) }
            } catch { library.error = error.localizedDescription }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let movie = UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true
        add(file, kind: movie ? .video : .image, title: file.deletingPathExtension().lastPathComponent)
    }
}
