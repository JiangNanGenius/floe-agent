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
    private let onGoal: ((String, CanvasTemplate?) -> Void)?
    @State private var query = ""
    @State private var goal = ""
    @State private var category: TemplateCategory?
    @State private var chosenTemplate: CanvasTemplate?
    public init(personal: [CanvasTemplate] = [], recent: [CanvasTemplate] = [],
                chinese: Bool = true, onGoal: ((String, CanvasTemplate?) -> Void)? = nil,
                onChoose: @escaping (CanvasTemplate?) -> Void) {
        self.personal = personal; self.recent = recent
        self.chinese = chinese; self.onChoose = onChoose; self.onGoal = onGoal
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let onGoal {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(chinese ? "想做些什么？" : "What would you like to make?").font(.title2.bold())
                        TextField(chinese ? "描述目标，或从下面选一个场景" : "Describe a goal, or choose a scenario below",
                                  text: $goal, axis: .vertical)
                            .lineLimit(3...5).padding(14)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("canvas.start.goal")
                        HStack {
                            if let chosenTemplate {
                                Label(chosenTemplate.title.value(chinese: chinese), systemImage: icon(chosenTemplate.category))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(chinese ? "创建画布" : "Create canvas", systemImage: "arrow.right") {
                                onGoal(goal.trimmingCharacters(in: .whitespacesAndNewlines), chosenTemplate ?? BuiltInCanvasTemplates.all.first)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("canvas.start.createGoal")
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(chinese ? "从场景开始" : "Start with a scenario").font(.title3.bold())
                    Spacer()
                    Button(chinese ? "空白画布" : "Blank canvas", systemImage: "doc.badge.plus") { onChoose(nil) }
                        .accessibilityIdentifier("canvas.start.blank")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        filterButton(chinese ? "全部" : "All", value: nil)
                        ForEach(TemplateCategory.allCases, id: \.self) { value in
                            filterButton(categoryTitle(value), value: value)
                        }
                    }
                }.scrollIndicators(.hidden)
                if !recent.isEmpty { section(chinese ? "最近使用" : "Recent", recent) }
                section(chinese ? "场景与流程" : "Scenarios and workflows", BuiltInCanvasTemplates.all)
                if !personal.isEmpty { section(chinese ? "我的流程" : "My workflows", personal) }
            }.padding(24)
        }
        .searchable(text: $query, prompt: chinese ? "查找流程" : "Find workflows")
        .navigationTitle(chinese ? "新建画布" : "New canvas")
        .background(Color.secondary.opacity(0.04))
    }
    private func section(_ name: String, _ templates: [CanvasTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: [.init(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(templates.filter { (category == nil || $0.category == category) && (query.isEmpty
                    || $0.title.zh.localizedCaseInsensitiveContains(query)
                    || $0.title.en.localizedCaseInsensitiveContains(query)) }) { template in
                    Button {
                        if onGoal != nil && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            chosenTemplate = template
                        } else { onChoose(template) }
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: icon(template.category)).font(.title2).foregroundStyle(.tint)
                                Spacer()
                                if chosenTemplate?.id == template.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }
                            Text(template.title.value(chinese: chinese)).font(.headline).foregroundStyle(.primary)
                            Text(template.summary.value(chinese: chinese)).font(.subheadline)
                                .foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 4) {
                                ForEach(0..<min(5, template.snapshot.pages.first?.flowGraphs.first?.nodes.count ?? 0), id: \.self) { index in
                                    if index > 0 { Rectangle().fill(.secondary.opacity(0.3)).frame(width: 12, height: 1) }
                                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.14)).frame(width: 24, height: 18)
                                }
                            }.accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(chosenTemplate?.id == template.id ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: chosenTemplate?.id == template.id ? 2 : 1))
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("canvas.template." + template.id.uuidString)
                }
            }
        }
    }
    private func filterButton(_ title: String, value: TemplateCategory?) -> some View {
        Button { category = value } label: {
            Text(title).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 9)
                .background(category == value ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain)
    }
    private func categoryTitle(_ value: TemplateCategory) -> String {
        switch value {
        case .research: chinese ? "研究" : "Research"
        case .ideas: chinese ? "构思" : "Ideas"
        case .image: chinese ? "图像" : "Images"
        case .video: chinese ? "视频" : "Video"
        case .music: chinese ? "音乐" : "Music"
        case .film: chinese ? "影视" : "Film"
        case .audio: chinese ? "音频" : "Audio"
        case .design: chinese ? "设计" : "Design"
        }
    }
    private func icon(_ value: TemplateCategory) -> String {
        switch value {
        case .research: "doc.text.magnifyingglass"
        case .ideas: "lightbulb"
        case .image: "photo.on.rectangle.angled"
        case .video: "video"
        case .music: "music.note"
        case .film: "film"
        case .audio: "waveform"
        case .design: "cube.transparent"
        }
    }
}
