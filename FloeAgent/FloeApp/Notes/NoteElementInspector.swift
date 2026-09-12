// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

struct NoteElementInspector: View {
    @State private var draft: NoteElement
    let page: NotePage
    let save: (NoteElement) -> Void
    let delete: () -> Void
    let openSource: ((NoteSourceReference) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(element: NoteElement, page: NotePage, save: @escaping (NoteElement) -> Void, delete: @escaping () -> Void, openSource: ((NoteSourceReference) -> Void)? = nil) {
        _draft = State(initialValue: element); self.page = page; self.save = save; self.delete = delete
        self.openSource = openSource
    }

    var body: some View {
        NavigationStack {
            Form {
                if let source = draft.source {
                    Section("来源") {
                        Label(draft.isAIGenerated ? "AI 生成的整理" : "引用内容", systemImage: "quote.opening")
                        Text("引用版本：\(source.revision)").font(.caption).foregroundStyle(.secondary)
                        if source.space == .notes, let openSource {
                            Button("打开源资料的当前页面") { openSource(source) }
                        }
                    }
                }
                if draft.kind == .text {
                    Section("文字") {
                        TextEditor(text: $draft.text).frame(minHeight: 160)
                        Stepper("字号 \(Int(draft.fontSize))", value: $draft.fontSize, in: 8...128, step: 1)
                    }
                }
                if draft.kind != .image {
                    Section("颜色") {
                        HStack(spacing: 16) {
                            ForEach(["#202020", "#D32F2F", "#1565C0", "#2E7D32", "#7B1FA2", "#E65100"], id: \.self) { hex in
                                Button { draft.color = hex } label: {
                                    Circle().fill(Color(uiColor: NotePageRenderer.color(hex)))
                                        .overlay { if draft.color == hex { Image(systemName: "checkmark").foregroundStyle(.white) } }
                                        .frame(width: 36, height: 36)
                                }.buttonStyle(.plain).accessibilityLabel(hex)
                            }
                        }
                    }
                }
                Section("位置与尺寸") {
                    dimension("水平位置", value: $draft.frame.x, maximum: page.width)
                    dimension("垂直位置", value: $draft.frame.y, maximum: page.height)
                    dimension("宽度", value: $draft.frame.width, minimum: min(20, page.width), maximum: page.width)
                    dimension("高度", value: $draft.frame.height, minimum: min(20, page.height), maximum: page.height)
                    Button("居中") {
                        draft.frame.x = max(0, (page.width - draft.frame.width) / 2)
                        draft.frame.y = max(0, (page.height - draft.frame.height) / 2)
                    }
                }
                Section {
                    Button("删除此内容", role: .destructive, action: delete)
                } footer: { Text("修改和删除均可通过手记的撤销按钮恢复。") }
            }
            .navigationTitle("页面内容")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save(draft) }
                        .disabled(!draft.frame.isValid || (draft.kind == .text && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }.presentationDetents([.large])
    }

    private func dimension(_ title: String, value: Binding<Double>, minimum: Double = 0, maximum: Double) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(0))).foregroundStyle(.secondary) }
            Slider(value: value, in: minimum...maximum)
        }
    }
}
#endif
