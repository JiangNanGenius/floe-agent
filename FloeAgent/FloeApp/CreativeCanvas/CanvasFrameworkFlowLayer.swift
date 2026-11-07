// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeCanvasCore
import FloeCanvasUI
import FloeDiagramCore
import FloeDiagramLayout

extension Notification.Name {
    static let floeCanvasFrameworkFlowRequested = Notification.Name("floe.canvas.framework.flow")
}

/// A flow overlay uses the old board's exact pan/zoom. It is a feature layer,
/// not another board or a second editable canvas document.
struct CanvasFrameworkFlowLayer: View {
    @ObservedObject var store: CanvasEditorStore
    let document: FloeCore.CanvasDocument
    let scale: Double
    let screenPoint: (CGPoint) -> CGPoint
    let isCurrent: () -> Bool
    let onCommitted: () -> Void
    let onError: (String) -> Void
    @State private var pendingPort: PortTicket?
    @State private var inspector: CanvasFrameworkFlowRequest?
    private struct PortTicket {
        let pageID: UUID
        let revision: Int64
        let port: CanvasFrameworkFlowPresentation.Port
    }
    private var scene: CanvasFrameworkFlowPresentation {
        .make(snapshot: store.snapshot, document: document)
    }

    var body: some View {
        let presentation = scene
        ZStack {
            ForEach(presentation.edges) { edge in
                let path = edgePath(edge.value.geometry)
                path.stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 3]))
                    .allowsHitTesting(false)
                path.stroke(Color.black.opacity(0.001), lineWidth: 44)
                    .contentShape(path.strokedPath(.init(lineWidth: 44)))
                    .onTapGesture { inspect(edge.graphID) }
                    .contextMenu {
                        Button(IDELanguageRunText.t("查看流程", "Show workflow"), systemImage: "play.rectangle") { inspect(edge.graphID) }
                        Button(IDELanguageRunText.t("删除流程连线", "Delete workflow connection"), systemImage: "trash", role: .destructive) {
                            remove(edge)
                        }
                    }
                    .accessibilityLabel(IDELanguageRunText.t("流程连线", "Workflow connection"))
                    .accessibilityIdentifier("canvas.flow.edge." + edge.value.id.uuidString)
            }
            ForEach(presentation.unboundNodes) { node in
                CanvasFrameworkUnboundFlowCard(store: store, value: node, scale: scale,
                    isCurrent: isCurrent, onInspect: { inspect(node.graphID) }, onCommitted: onCommitted, onError: onError)
                    .frame(width: node.frame.width, height: node.frame.height)
                    .scaleEffect(scale)
                    .position(screenPoint(.init(x: node.frame.center.x, y: node.frame.center.y)))
            }
            ForEach(presentation.ports) { port in
                Button { choose(port) } label: {
                    Circle().fill(pendingPort?.port.id == port.id ? Color.orange : Color.accentColor)
                        .frame(width: 11, height: 11)
                        .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2) }
                        .frame(width: 44, height: 44).contentShape(.rect)
                }.buttonStyle(.plain)
                    .disabled(port.locked || store.isMutating)
                    .position(screenPoint(.init(x: port.point.x, y: port.point.y)))
                    .accessibilityLabel((port.value.direction == .output ? IDELanguageRunText.t("输出：", "Output: ") : IDELanguageRunText.t("输入：", "Input: ")) + port.value.name)
                    .accessibilityHint(IDELanguageRunText.t("先选择输出，再选择输入以连接步骤。", "Choose an output, then an input to connect steps."))
                    .accessibilityIdentifier("canvas.flow.port." + port.value.id.uuidString)
            }
        }
        .sheet(item: $inspector) { request in CanvasFrameworkFlowInspector(store: store, request: request) }
        .onChange(of: document.id) { _, _ in pendingPort = nil; inspector = nil }
        .onChange(of: store.revision) { _, _ in pendingPort = nil; onCommitted() }
        .onChange(of: store.alert?.id) { _, _ in
            if let alert = store.alert { onError(alert.message) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeCanvasFrameworkFlowRequested)) { message in
            guard message.userInfo?["canvasID"] as? UUID == store.canvasID,
                  message.userInfo?["pageID"] as? UUID == document.id,
                  let graphID = message.userInfo?["graphID"] as? UUID else { return }
            inspect(graphID)
        }
    }

    private func edgePath(_ geometry: DiagramEdgeGeometry) -> Path {
        var path = Path()
        path.move(to: screenPoint(.init(x: geometry.start.x, y: geometry.start.y)))
        for segment in geometry.segments {
            switch segment {
            case .line(let end): path.addLine(to: screenPoint(.init(x: end.x, y: end.y)))
            case .cubic(let a, let b, let end):
                path.addCurve(to: screenPoint(.init(x: end.x, y: end.y)),
                    control1: screenPoint(.init(x: a.x, y: a.y)), control2: screenPoint(.init(x: b.x, y: b.y)))
            }
        }
        let points = geometry.polyline()
        if let previous = points.dropLast().last {
            let end = screenPoint(.init(x: geometry.end.x, y: geometry.end.y))
            let before = screenPoint(.init(x: previous.x, y: previous.y))
            let angle = atan2(end.y - before.y, end.x - before.x)
            path.move(to: .init(x: end.x - 10 * cos(angle - .pi / 6), y: end.y - 10 * sin(angle - .pi / 6)))
            path.addLine(to: end)
            path.addLine(to: .init(x: end.x - 10 * cos(angle + .pi / 6), y: end.y - 10 * sin(angle + .pi / 6)))
        }
        return path
    }
    private func inspect(_ graphID: UUID) {
        guard isCurrent(), store.page.id == document.id,
              store.page.flowGraphs.contains(where: { $0.id == graphID }) else { return }
        store.selectFlowGraph(graphID)
        inspector = .init(canvasID: store.canvasID, pageID: document.id, graphID: graphID)
    }
    private func choose(_ port: CanvasFrameworkFlowPresentation.Port) {
        guard isCurrent(), store.page.id == document.id, !port.locked else { return }
        store.selectFlowGraph(port.graphID)
        if port.value.direction == .output {
            pendingPort = .init(pageID: document.id, revision: store.revision, port: port)
            return
        }
        guard let pending = pendingPort, pending.pageID == document.id,
              pending.revision == store.revision, pending.port.graphID == port.graphID else {
            pendingPort = nil
            onError(IDELanguageRunText.t("请先选择这个流程的输出端口。", "Choose an output port in this workflow first.")); return
        }
        let snapshot = store.snapshot
        pendingPort = nil
        Task { @MainActor in
            guard isCurrent(), store.page.id == document.id, store.revision == pending.revision else { return }
            do {
                let batch = try CanvasFlowGraphEditing.connectPortsBatch(snapshot: snapshot, pageID: document.id,
                    sourceNodeID: pending.port.nodeID, sourcePortID: pending.port.value.id,
                    destinationNodeID: port.nodeID, destinationPortID: port.value.id)
                await store.commit(batch, undoLabel: IDELanguageRunText.t("连接流程步骤", "Connect workflow steps"), expectedRevision: pending.revision)
                onCommitted()
            } catch { onError(error.localizedDescription) }
        }
    }
    private func remove(_ edge: CanvasFrameworkFlowPresentation.Edge) {
        let snapshot = store.snapshot
        guard isCurrent(), store.page.id == document.id,
              var graph = store.page.flowGraphs.first(where: { $0.id == edge.graphID }), graph.revision < Int64.max else { return }
        graph.edges.removeAll { $0.id == edge.value.id }; graph.revision += 1
        let batch = CanvasDocumentBatch(operations: [.replaceFlowGraph(graph: graph)])
        Task { @MainActor in
            guard isCurrent(), store.page.id == document.id else { return }
            await store.commit(batch, undoLabel: IDELanguageRunText.t("删除流程连线", "Delete workflow connection"), expectedRevision: snapshot.revision)
            onCommitted()
        }
    }
}

private struct CanvasFrameworkUnboundFlowCard: View {
    @ObservedObject var store: CanvasEditorStore
    let value: CanvasFrameworkFlowPresentation.UnboundNode
    let scale: Double
    let isCurrent: () -> Bool
    let onInspect: () -> Void
    let onCommitted: () -> Void
    let onError: (String) -> Void
    @State private var offset = CGSize.zero
    @State private var dragBase: CanvasSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(value.value.name, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.semibold)).lineLimit(2)
            Button(IDELanguageRunText.t("查看流程", "Show workflow"), systemImage: "play.rectangle", action: onInspect)
                .font(.caption).frame(minHeight: 44)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(.tint, lineWidth: 1.5) }
            .contentShape(.rect).onTapGesture(perform: onInspect)
            .offset(offset)
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                if dragBase == nil { dragBase = store.snapshot }
                offset = .init(width: value.translation.width / max(0.05, scale), height: value.translation.height / max(0.05, scale))
            }.onEnded { _ in commitPosition() })
            .accessibilityIdentifier("canvas.flow.node." + value.value.id.uuidString)
    }
    private func commitPosition() {
        guard let base = dragBase else { return }
        dragBase = nil
        var node = value.value
        node.position = .init(x: node.position.x + Double(offset.width), y: node.position.y + Double(offset.height))
        offset = .zero
        let pageID = store.selectedPageID
        Task { @MainActor in
            guard isCurrent(), store.selectedPageID == pageID else { return }
            do {
                let batch = try CanvasFlowGraphEditing.updateNodeBatch(snapshot: base, pageID: pageID, node: node)
                await store.commit(batch, undoLabel: IDELanguageRunText.t("移动流程步骤", "Move workflow step"), expectedRevision: base.revision)
                onCommitted()
            } catch { onError(error.localizedDescription) }
        }
    }
}

struct CanvasFrameworkFlowRequest: Identifiable {
    let id = UUID()
    let canvasID: UUID
    let pageID: UUID
    let graphID: UUID
}

struct CanvasFrameworkFlowInspector: View {
    @ObservedObject var store: CanvasEditorStore
    let request: CanvasFrameworkFlowRequest
    @Environment(\.dismiss) private var dismiss
    @State private var definition = false
    private var available: Bool {
        store.canvasID == request.canvasID && store.page.id == request.pageID
            && store.page.flowGraphs.contains { $0.id == request.graphID }
    }
    var body: some View {
        NavigationStack {
            Group {
                if available { CanvasFlowDebuggerView(store: store) }
                else { ContentUnavailableView(IDELanguageRunText.t("流程已更改", "Workflow changed"), systemImage: "point.3.connected.trianglepath.dotted") }
            }
            .navigationTitle(IDELanguageRunText.t("流程调试", "Workflow debugger"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(IDELanguageRunText.t("运行", "Run"), systemImage: "play.fill") {
                        store.selectFlowGraph(request.graphID)
                        Task { _ = await store.startFlowRun() }
                    }.disabled(!available || store.isMutating)
                        .accessibilityIdentifier("canvas.framework.flow.run")
                    Spacer()
                    Button(IDELanguageRunText.t("编辑步骤", "Edit steps"), systemImage: "slider.horizontal.3") { definition = true }
                        .disabled(!available || store.isMutating)
                        .accessibilityIdentifier("canvas.framework.flow.edit")
                }
            }
        }
        .sheet(isPresented: $definition) { CanvasFlowDefinitionEditor(store: store, graphID: request.graphID) }
        .task { if available { store.selectFlowGraph(request.graphID) } }
    }
}
#endif
