import SwiftUI
import FloeCanvasTemplates

/// Embed in an empty canvas. This is a nonmodal starting aid, not a gate.
/// The host owns the canvas and routes selection to append(), never another editor state.
public struct CanvasTemplateStartView: View {
    private let chinese: Bool
    private let onChoose: (CanvasTemplate) -> Void
    private let onBrowse: () -> Void
    public init(chinese: Bool = true, onChoose: @escaping (CanvasTemplate) -> Void,
                onBrowse: @escaping () -> Void) {
        self.chinese = chinese; self.onChoose = onChoose; self.onBrowse = onBrowse
    }
    public var body: some View {
        VStack(spacing: 16) {
            Text(chinese ? "从想法开始" : "Start with an idea").font(.title2)
            Text(chinese ? "加入内容，或选一个流程开始。" : "Add content, or start with a workflow.")
                .foregroundStyle(.secondary)
            ViewThatFits {
                HStack { shortcuts }
                VStack { shortcuts }
            }
            Button(chinese ? "浏览流程" : "Browse workflows", action: onBrowse)
        }.padding()
    }
    @ViewBuilder private var shortcuts: some View {
        ForEach(BuiltInCanvasTemplates.all.filter { [.image, .video, .music].contains($0.category) }.prefix(4)) { template in
            Button(template.title.value(chinese: chinese)) { onChoose(template) }
                .buttonStyle(.bordered)
        }
    }
}

public struct CanvasTemplatePicker: View {
    private let chinese: Bool
    private let personal: [CanvasTemplate]
    private let recent: [CanvasTemplate]
    private let onChoose: (CanvasTemplate?) -> Void
    @State private var query = ""
    public init(personal: [CanvasTemplate] = [], recent: [CanvasTemplate] = [],
                chinese: Bool = true, onChoose: @escaping (CanvasTemplate?) -> Void) {
        self.personal = personal; self.recent = recent
        self.chinese = chinese; self.onChoose = onChoose
    }
    public var body: some View {
        List {
            Button(chinese ? "空白画布" : "Blank canvas") { onChoose(nil) }
            if !recent.isEmpty { section(chinese ? "最近使用" : "Recent", recent) }
            section(chinese ? "预置流程" : "Presets", BuiltInCanvasTemplates.all)
            section(chinese ? "我的流程" : "My workflows", personal)
        }
        .searchable(text: $query, prompt: chinese ? "查找流程" : "Find workflows")
        .navigationTitle(chinese ? "流程" : "Workflows")
    }
    private func section(_ name: String, _ templates: [CanvasTemplate]) -> some View {
        Section(name) {
            ForEach(templates.filter { query.isEmpty
                || $0.title.zh.localizedCaseInsensitiveContains(query)
                || $0.title.en.localizedCaseInsensitiveContains(query) }) { template in
                Button { onChoose(template) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.title.value(chinese: chinese))
                        Text(template.summary.value(chinese: chinese))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
}
