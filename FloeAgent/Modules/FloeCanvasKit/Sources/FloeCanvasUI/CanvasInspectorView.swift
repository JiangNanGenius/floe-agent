#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore
import FloeCanvasLayout

/// Contextual inspector. Tabs pick themselves from the selection
/// (`CanvasInspectorTab.defaultTab`); everything here edits through the
/// store as single committed batches.
public struct CanvasInspectorView: View {
    @ObservedObject var store: CanvasEditorStore
    @ObservedObject var previews: CanvasPreviewPipeline

    private var strings: CanvasStrings { store.strings }

    public init(store: CanvasEditorStore, previews: CanvasPreviewPipeline) {
        self.store = store
        self.previews = previews
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker(strings[.inspectorTitle], selection: $store.inspectorTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            Divider()
            ScrollView {
                content
                    .padding(12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.inspector.identifier)
    }

    private var availableTabs: [CanvasInspectorTab] {
        guard let node = store.singleSelectedNode else {
            return [.node]
        }
        var tabs: [CanvasInspectorTab] = [.node, .style]
        if CanvasFlowCardBinding(metadata: node.metadata) != nil { tabs.append(.flow) }
        if node.source != nil { tabs.append(.source) }
        if isResource(node) { tabs.append(.resource) }
        return tabs
    }

    @ViewBuilder
    private var content: some View {
        if let node = store.singleSelectedNode {
            switch store.inspectorTab {
            case .node: NodeInspectorTab(store: store, node: node)
            case .style: StyleInspectorTab(store: store, node: node)
            case .flow: FlowInspectorTab(store: store, node: node)
            case .source: SourceInspectorTab(store: store, node: node)
            case .resource: ResourceInspectorTab(store: store, node: node, previews: previews)
            case .debugger: DebuggerSummaryTab(store: store)
            }
        } else if !store.selection.isEmpty {
            MultiSelectionInspector(store: store)
        } else {
            Text(strings[.inspectorNoSelection])
                .foregroundStyle(.secondary)
        }
    }

    private func tabLabel(_ tab: CanvasInspectorTab) -> String {
        switch tab {
        case .node: return strings[.inspectorNodeTitle]
        case .style: return strings[.inspectorStyle]
        case .flow: return strings[.inspectorFlowBinding]
        case .source: return strings[.inspectorSourceUsedRevision]
        case .resource: return strings[.inspectorResources]
        case .debugger: return strings[.debuggerTitle]
        }
    }

    private func isResource(_ node: CanvasNodeSnapshot) -> Bool {
        switch node.content {
        case .media, .pdf, .editor: return true
        default: return false
        }
    }
}

// MARK: - Shared field

struct CanvasField: View {
    let title: String
    @State var text: String
    let onCommit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit(text) }
        }
    }
}

// MARK: - Node tab

struct NodeInspectorTab: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CanvasField(
                title: strings[.inspectorNodeTitle],
                text: node.title ?? "",
                onCommit: { newValue in
                    Task { await store.apply(.updateTitle(
                        node.id, newValue.isEmpty ? nil : newValue)) }
                })
            VStack(alignment: .leading, spacing: 6) {
                Text(strings[.inspectorNodeContent])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.focusNode(node.id)
                } label: {
                    Label(
                        contentLabel,
                        systemImage: contentIcon)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.inspectorContentEditor.identifier)
            }
            Toggle(strings[.inspectorLocked], isOn: .init(
                get: { node.isLocked },
                set: { newValue in
                    Task { await store.apply(.setLocked([node.id], newValue)) }
                }))
            .accessibilityIdentifier(CanvasAccessibilityID.inspectorLockedSwitch.identifier)
        }
    }

    private var contentLabel: String {
        switch node.content {
        case .text: return store.strings[.insertText]
        case .richText: return store.strings[.insertRichText]
        case .markdown: return store.strings[.insertMarkdown]
        case .table: return store.strings[.insertTable]
        case .formula: return store.strings[.insertFormula]
        case .code: return store.strings[.insertCode]
        case .shape: return store.strings[.insertShapeRectangle]
        case .media: return store.strings[.insertMedia]
        case .pdf: return store.strings[.insertPDF]
        case .web: return store.strings[.insertWebReference]
        case .editor: return store.strings[.insertEditorPreview]
        case .unknown: return store.strings[.inspectorNodeContent]
        }
    }

    private var contentIcon: String {
        switch node.content {
        case .text: return "textformat"
        case .richText: return "textformat.abc"
        case .markdown: return "doc.richtext"
        case .table: return "tablecells"
        case .formula: return "function"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .shape: return "square"
        case .media: return "photo"
        case .pdf: return "doc.text"
        case .web: return "globe"
        case .editor: return "shippingbox"
        case .unknown: return "questionmark.square"
        }
    }
}

// MARK: - Style tab

struct StyleInspectorTab: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            styleField(strings[.inspectorFillColor], CanvasVisualMetadataKeys.fillColor)
            styleField(strings[.inspectorStrokeColor], CanvasVisualMetadataKeys.strokeColor)
            styleField(strings[.inspectorTextColor], CanvasVisualMetadataKeys.textColor)
            VStack(alignment: .leading) {
                Text(strings[.inspectorStrokeWidth])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: strokeWidthBinding, in: 0...24) {
                    Text(String(format: "%.1f", strokeWidthBinding.wrappedValue))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.inspectorStyleSection.identifier)
    }

    private var style: CanvasVisualStyle {
        CanvasVisualStyle(metadata: node.metadata) ?? CanvasVisualStyle()
    }

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { style.strokeWidth ?? 1 },
            set: { newValue in applyStyle(style.withStrokeWidth(newValue)) })
    }

    private func styleField(_ title: String, _ key: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: Binding(
                get: { node.metadata[key] ?? "" },
                set: { newValue in
                    var next = style
                    next = next.replacingValue(newValue, forKey: key)
                    applyStyle(next)
                }))
            .textFieldStyle(.roundedBorder)
        }
    }

    private func applyStyle(_ newStyle: CanvasVisualStyle) {
        var values: [String: String] = [:]
        var removing: [String] = []
        if let fill = newStyle.fillColor { values[CanvasVisualMetadataKeys.fillColor] = fill }
        else { removing.append(CanvasVisualMetadataKeys.fillColor) }
        if let stroke = newStyle.strokeColor { values[CanvasVisualMetadataKeys.strokeColor] = stroke }
        else { removing.append(CanvasVisualMetadataKeys.strokeColor) }
        if let text = newStyle.textColor { values[CanvasVisualMetadataKeys.textColor] = text }
        else { removing.append(CanvasVisualMetadataKeys.textColor) }
        if let width = newStyle.strokeWidth {
            values[CanvasVisualMetadataKeys.strokeWidth] = String(width)
        } else {
            removing.append(CanvasVisualMetadataKeys.strokeWidth)
        }
        Task {
            await store.apply(.updateNodeMetadata(
                node.id, values: values, removingKeys: removing))
        }
    }
}

private extension CanvasVisualStyle {
    func withStrokeWidth(_ width: Double) -> CanvasVisualStyle {
        var copy = self
        copy.strokeWidth = width
        return copy
    }

    func replacingValue(_ value: String, forKey key: String) -> CanvasVisualStyle {
        var copy = self
        switch key {
        case CanvasVisualMetadataKeys.fillColor: copy.fillColor = value.isEmpty ? nil : value
        case CanvasVisualMetadataKeys.strokeColor: copy.strokeColor = value.isEmpty ? nil : value
        case CanvasVisualMetadataKeys.textColor: copy.textColor = value.isEmpty ? nil : value
        default: break
        }
        return copy
    }
}

// MARK: - Flow tab

struct FlowInspectorTab: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    private var strings: CanvasStrings { store.strings }
    @State private var showsDefinition = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let flowNode = boundFlowNode {
                kindHeader(flowNode)
                switch flowNode.kind {
                case .condition:
                    ConditionFlowEditor(store: store, node: node, flowNode: flowNode)
                case .loop:
                    LoopFlowEditor(store: store, node: node, flowNode: flowNode)
                case .batch:
                    BatchFlowEditor(store: store, node: node, flowNode: flowNode)
                case .customScript, .customAPI:
                    ExternalFlowEditor(store: store, node: node, flowNode: flowNode)
                case .subgraph:
                    SubgraphFlowEditor(store: store, node: node, flowNode: flowNode)
                default:
                    PortsFlowEditor(store: store, node: node, flowNode: flowNode)
                }
                PortsFlowEditor(store: store, node: node, flowNode: flowNode)
                validationSummary(flowNode)
                Button(strings[.flowDefinitionTitle]) { showsDefinition = true }
                    .accessibilityIdentifier("floe.canvas.flow.editDefinition")
            } else {
                Text(strings[.inspectorNoSelection])
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.inspectorFlowSection.identifier)
        .sheet(isPresented: $showsDefinition) {
            if let binding = CanvasFlowCardBinding(metadata: node.metadata) {
                CanvasFlowDefinitionEditor(store: store, graphID: binding.graphID)
            }
        }
    }

    private var boundFlowNode: FlowNode? {
        guard let binding = CanvasFlowCardBinding(metadata: node.metadata),
              let graph = store.page.flowGraphs.first(where: { $0.id == binding.graphID }) else {
            return nil
        }
        return graph.nodes.first(where: { $0.id == binding.nodeID })
    }

    private func kindHeader(_ flowNode: FlowNode) -> some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
            Text(kindName(flowNode.kind))
                .font(.headline)
        }
    }

    private func kindName(_ kind: FlowNodeKind) -> String {
        switch kind {
        case .source: return strings[.flowKindSource]
        case .transform: return strings[.flowKindTransform]
        case .condition: return strings[.flowKindCondition]
        case .loop: return strings[.flowKindLoop]
        case .batch: return strings[.flowKindBatch]
        case .subgraph: return strings[.flowKindSubgraph]
        case .customScript: return strings[.flowKindCustomScript]
        case .customAPI: return strings[.flowKindCustomAPI]
        case .output: return strings[.flowKindOutput]
        }
    }

    private func validationSummary(_ flowNode: FlowNode) -> some View {
        let issues = CanvasFlowInspectorIssues.issues(
            for: flowNode,
            environmentID: store.services.makeRunConfiguration == nil
                ? ""
                : "configured")
        return Group {
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings[.flowValidationIssues])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(issues, id: \.self) { issue in
                        Text("• \(issue)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

/// Actionable per-kind configuration checks (script/API environment etc).
enum CanvasFlowInspectorIssues {
    static func issues(for node: FlowNode, environmentID: String) -> [String] {
        var result: [String] = []
        switch node.kind {
        case .customScript:
            if environmentID.isEmpty {
                result.append("script: no execution environment")
            }
            if node.script == nil {
                result.append("script: descriptor missing")
            }
        case .customAPI:
            if environmentID.isEmpty {
                result.append("api: no execution environment")
            }
            if node.api == nil {
                result.append("api: descriptor missing")
            }
        case .subgraph:
            if node.subgraphTemplateID == nil {
                result.append("subgraph: no template bound")
            }
        case .loop:
            let max = node.parameters["maxIterations"]?.numberValue
            if max == nil {
                result.append("loop: maxIterations defaults to 100")
            }
        default:
            break
        }
        return result
    }
}

private extension JSONValue {
    var numberValue: Double? {
        guard case .number(let literal) = self else { return nil }
        return Double(literal)
    }
}

// MARK: - Shared flow editors

struct FlowNodeUpdate {
    static func commit(
        store: CanvasEditorStore,
        flowNode: FlowNode,
        mutate: (inout FlowNode) -> Void
    ) {
        var updated = flowNode
        mutate(&updated)
        Task {
            await store.apply(.updateFlowNode(updated))
        }
    }
}

struct ConditionFlowEditor: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    let flowNode: FlowNode
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings[.flowConditionBranches])
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Branches: \(flowNode.branches?.count ?? 0)")
                .font(.caption)
        }
    }
}

struct LoopFlowEditor: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    let flowNode: FlowNode
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings[.flowMaxIterations])
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: {
                    flowNode.parameters["maxIterations"]
                        .flatMap { $0.numberValue }.map(Int.init) ?? 100
                },
                set: { newValue in
                    FlowNodeUpdate.commit(store: store, flowNode: flowNode) {
                        $0.parameters["maxIterations"] = .number(String(newValue))
                    }
                }), in: 1...10_000) {
                Text("\(flowNode.parameters["maxIterations"].flatMap { $0.numberValue }.map(Int.init) ?? 100)")
            }
        }
    }
}

struct BatchFlowEditor: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    let flowNode: FlowNode
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        Text(strings[.flowVariables])
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct ExternalFlowEditor: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    let flowNode: FlowNode
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.services.makeRunConfiguration == nil
                && (flowNode.kind == .customScript || flowNode.kind == .customAPI) {
                Label(
                    strings[.flowScriptMissingEnvironment],
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if flowNode.kind == .customScript {
                Text("hash: \(flowNode.script?.sourceHash ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(flowNode.api?.endpoint.absoluteString ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SubgraphFlowEditor: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    let flowNode: FlowNode
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        Text(flowNode.subgraphTemplateID?.uuidString ?? strings[.inspectorNoSelection])
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

struct PortsFlowEditor: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    let flowNode: FlowNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(flowNode.ports) { port in
                HStack {
                    Image(systemName: port.direction == .input
                        ? "arrow.down.to.line" : "arrow.up.from.line")
                    Text(port.name)
                    Spacer()
                    Text(port.dataType.rawValue)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Source tab (ICH04)

struct SourceInspectorTab: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = node.source {
                LabeledContent(strings[.inspectorSourceUsedRevision], value: "\(source.usedRevision)")
                ForEach(source.annotations) { annotation in
                    VStack(alignment: .leading) {
                        Text(annotation.text)
                        Text(annotation.author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button(strings[.inspectorRefreshSource]) {
                        Task {
                            await store.refreshSource(
                                nodeID: node.id, instruction: .default)
                        }
                    }
                    .accessibilityIdentifier(CanvasAccessibilityID.inspectorRefreshSourceButton.identifier)
                    Menu(strings[.inspectorRefreshSource]) {
                        Button(strings[.inspectorRefreshSourceReplace]) {
                            Task {
                                await store.refreshSource(
                                    nodeID: node.id, instruction: .replace)
                            }
                        }
                        Button(strings[.inspectorRefreshSourceBranch]) {
                            Task {
                                await store.refreshSource(
                                    nodeID: node.id, instruction: .branch)
                            }
                        }
                    }
                }
                Button(strings[.inspectorOpenOriginal]) {
                    Task { await store.openOriginalSource(nodeID: node.id) }
                }
            } else {
                Text(strings[.inspectorNoSelection])
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.inspectorSourceSection.identifier)
    }
}

// MARK: - Resource tab

struct ResourceInspectorTab: View {
    @ObservedObject var store: CanvasEditorStore
    let node: CanvasNodeSnapshot
    @ObservedObject var previews: CanvasPreviewPipeline
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch node.content {
            case .media(let locator):
                MediaPreview(locator: locator, previews: previews, store: store)
            case .pdf(let assetID, let pageRange):
                Text("PDF \(assetID?.uuidString ?? "—") · \(pageRangeText(pageRange))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let assetID {
                    // Same bounded host gate as the board: the host preview
                    // service resolves PDF thumbnails; the kit never renders
                    // PDF pages itself.
                    MediaPreview(
                        locator: CanvasAssetLocator(
                            id: assetID,
                            mimeType: "application/pdf"),
                        previews: previews,
                        store: store,
                        contentKind: "pdf")
                } else {
                    Text(strings[.pdfMissingDocument])
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .editor(let reference):
                LabeledContent("project", value: reference.projectID.uuidString)
                    .font(.caption2)
                LabeledContent("revision", value: "\(reference.appliedRevision)")
                    .font(.caption2)
                Button(strings[.inspectorOpenEditor]) {
                    Task { await store.openEditorForSelectedNode() }
                }
                .accessibilityIdentifier(CanvasAccessibilityID.inspectorOpenEditorButton.identifier)
                Button(strings[.inspectorApplyEditorResult]) {
                    Task { await store.applyEditorResult() }
                }
                .accessibilityIdentifier(CanvasAccessibilityID.inspectorApplyEditorButton.identifier)
                Button("Fork") {
                    Task { await store.forkEditorProject() }
                }
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.inspectorResourceSection.identifier)
    }

    private func pageRangeText(_ range: ClosedRange<Int>?) -> String {
        guard let range else { return "all" }
        return "\(range.lowerBound)–\(range.upperBound)"
    }
}

struct MediaPreview: View {
    let locator: CanvasAssetLocator
    @ObservedObject var previews: CanvasPreviewPipeline
    @ObservedObject var store: CanvasEditorStore
    var contentKind: String? = nil
    @State private var image: UIImage?
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label(strings[.mediaTapToResolve], systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let hash = locator.contentHash {
                Text(hash.prefix(16) + "…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task(id: locator.id) {
            image = nil
            let entry = await previews.preview(
                for: locator,
                contentKind: contentKind ?? locator.mimeType)
            image = entry?.image
        }
    }
}

// MARK: - Multi-selection + debugger summary

struct MultiSelectionInspector: View {
    @ObservedObject var store: CanvasEditorStore
    private var strings: CanvasStrings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.formatted(.a11ySelectionCount, store.selection.count))
                .font(.headline)
            Button(strings[.toolbarGroup]) {
                Task { await store.apply(.groupSelection) }
            }
            Button(strings[.toolbarRegion]) {
                Task { await store.apply(.createRegionForSelection(name: nil)) }
            }
            Button(strings[.toolbarDelete]) {
                Task { await store.apply(.deleteSelection) }
            }
        }
    }
}

struct DebuggerSummaryTab: View {
    @ObservedObject var store: CanvasEditorStore

    var body: some View {
        CanvasFlowDebuggerView(store: store)
    }
}
#endif
