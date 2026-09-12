// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import PencilKit
import FloeNotes

@main struct NotesQualificationApp: App {
    var body: some Scene { WindowGroup { QualificationPage() } }
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
