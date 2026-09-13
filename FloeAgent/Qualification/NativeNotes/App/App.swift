// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import PencilKit
import FloeNotes

@main struct NotesQualificationApp: App {
    var body: some Scene { WindowGroup {
        if ProcessInfo.processInfo.arguments.contains("--linked-map-fixture") { LinkedMapQualificationPage() }
        else { QualificationPage() }
    } }
}
private struct QualificationPage: View {
    @State private var drawing: Data?
    @State private var region = false
    @State private var count = 0
    @State private var capture: UIImage?
    @State private var selectedTool = 0
    @State private var page = NotePage(paper: .grid, elements: [
        .init(frame: .init(x: 50, y: 50, width: 620, height: 90), text: "手记 · 原生定向测试\n中文公式与 English annotations", fontSize: 24)
    ])
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("此页面只用于组件验证，不代表完整应用验收。")
                    .font(.caption).padding()
                HStack {
                    Picker("工具", selection: $selectedTool) { Text("笔").tag(0); Text("套索").tag(1) }.pickerStyle(.segmented)
                    Toggle("AI 选区", isOn: $region)
                    Text("选中 \(count)")
                }.padding()
                NotePencilView(page: page, drawing: drawing, background: nil, fingerDrawing: true,
                               tool: selectedTool == 0 ? PKInkingTool(.pen, color: .black, width: 3) : PKLassoTool(),
                               onDrawing: { drawing = $0 }, onSelectionCount: { count = $0 },
                               regionSelection: region, onSelectionCapture: { _, data in capture = UIImage(data: data) })
                if let capture { Image(uiImage: capture).resizable().scaledToFit().frame(maxHeight: 160).accessibilityIdentifier("selection.capture") }
            }.navigationTitle("手记组件验证")
                .toolbar { NavigationLink("语音") { WhisperSettingsView() } }
        }
    }
}


private struct LinkedMapQualificationPage: View {
    @State private var session = NotesSession()
    @State private var parent: NoteDocument?
    @State private var link: NoteMindMapLink?
    @State private var background: Data?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("国际经济学 · 课件与导图").font(.headline)
                Spacer()
                Text("组件验证").font(.caption).foregroundStyle(.secondary)
            }.padding()
            if let parent {
                ZStack {
                    NotePencilView(page: parent.pages[0], drawing: nil, background: background, fingerDrawing: false,
                                   tool: PKInkingTool(.pen, color: .black, width: 3), onDrawing: { _ in })
                    if let link {
                        NotesMindMapWindow(parentSession: session, parentID: parent.id, link: link, close: { self.link = nil }, onAssistant: { _ in }).padding(12)
                    }
                }
            } else if let error { Text(error).accessibilityIdentifier("fixture.error") }
            else { ProgressView() }
        }.task {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-window-fixture")
                // Only this disposable qualification fixture; never the application's Notes store.
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                let store = try NotesStore(root: root)
                let url = root.appendingPathComponent("Economics.pdf")
                let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 768, height: 1024)).pdfData { context in
                    context.beginPage()
                    ("国际经济学 · International Economics" as NSString).draw(at: CGPoint(x: 48, y: 64), withAttributes: [.font: UIFont.systemFont(ofSize: 28, weight: .bold)])
                    ("Lecture 03 — Comparative advantage\n\n机会成本与贸易收益\n\n两国可以通过专业化分工提高总产出。\nCompare the opportunity cost before choosing a strategy." as NSString)
                        .draw(in: CGRect(x: 48, y: 130, width: 660, height: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
                }
                try data.write(to: url)
                let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
                let document = try await store.create(draft)
                let map = try await store.createLinkedMindMap(parentID: document.id, expectedRevision: document.revision, title: "比较优势", pageID: document.pages[0].id)
                let topics = [MindMapNode(parentID: map.nodes[0].id, title: "机会成本", order: 0), MindMapNode(parentID: map.nodes[0].id, title: "Trade gains", order: 1)]
                _ = try await store.apply(.init(documentID: map.id, expectedRevision: map.revision, title: "Fixture topics", edits: topics.map(NoteEdit.upsertNode)))
                await session.open(using: store); await session.select(document)
                background = try await NoteFileImporter.background(page: document.pages[0], store: store)
                parent = session.document
                link = parent?.linkedMindMaps?.first
            } catch { self.error = error.localizedDescription }
        }
    }
}
