// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDInspectorNumberField: View {
    let title: String
    @Binding var value: Double
    init(_ title: String, value: Binding<Double>) { self.title = title; _value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: $value, format: .number)
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

struct EDInspectorTextField: View {
    let title: String
    @Binding var text: String
    init(_ title: String, text: Binding<String>) { self.title = title; _text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

struct EDInspectorIntegerField: View {
    let title: String
    @Binding var value: Int
    init(_ title: String, value: Binding<Int>) { self.title = title; _value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: $value, format: .number)
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

struct EDInspectorPointFields: View {
    @Binding var point: EDAPoint
    let prefix: String
    init(_ point: Binding<EDAPoint>, prefix: String = "") { _point = point; self.prefix = prefix }
    var body: some View {
        HStack(alignment: .top) {
            EDInspectorNumberField(prefix + "X (mm)", value: $point.x)
            EDInspectorNumberField(prefix + "Y (mm)", value: $point.y)
        }
    }
}

struct EDInspectorPreview: View {
    let title: String
    let subtitle: String
    let scene: EDInspectorPreviewScene?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).textSelection(.enabled)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            if let scene {
                Canvas { context, size in
                    let projection = EDAProjection(bounds: scene.bounds, size: size)
                    EDAPlot.draw(project: scene.project, context: scene.context, projection: projection, in: &context)
                }
                .frame(height: 116)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(edText("所选对象图形预览", "Selected object preview"))
                .allowsHitTesting(false)
            } else {
                Text(edText("未找到图形定义。", "The graphic definition is unavailable."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One local draft, one existing session.apply transaction. No optional CAS
/// token or revision-driven view identity reset is used.
struct EDInspectorEditor<Value: Equatable & Sendable, Content: View>: View {
    let session: EDWorkbenchSession
    let source: (EDAProject) -> Value?
    let edits: (Value, EDAProject) throws -> [EDAEdit]
    let duplicate: ((Value, EDAProject) throws -> [EDAEdit])?
    let delete: ((Value, EDAProject) throws -> [EDAEdit])?
    let deleteLocked: (Value, EDAProject) -> Bool
    let saveTitle: String
    @ViewBuilder let content: (Binding<Value>) -> Content
    @State private var draft: EDInspectorDraft<Value>
    @State private var working = false

    init(session: EDWorkbenchSession, value: Value, source: @escaping (EDAProject) -> Value?,
         saveTitle: String = edText("应用修改", "Apply changes"),
         edits: @escaping (Value, EDAProject) throws -> [EDAEdit],
         duplicate: ((Value, EDAProject) throws -> [EDAEdit])? = nil,
         delete: ((Value, EDAProject) throws -> [EDAEdit])? = nil,
         deleteLocked: @escaping (Value, EDAProject) -> Bool = { _, _ in false },
         @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self.session = session; self.source = source; self.saveTitle = saveTitle
        self.edits = edits; self.duplicate = duplicate; self.delete = delete; self.deleteLocked = deleteLocked
        self.content = content; _draft = State(initialValue: .init(value, revision: session.revision))
    }
    private var unavailable: Bool { working || session.busy || session.isClosed || session.isRouting || session.isFilling }
    private var conflict: Bool { draft.needsReload || draft.revision != session.revision || session.conflictWithOriginal }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content($draft.value).disabled(unavailable)
            }.padding(16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .onChange(of: session.revision, initial: true) { _, revision in
            guard !working, let value = source(session.project) else { return }
            draft.receive(value, revision: revision)
        }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict
                 ? edText("原件已更改。你的输入仍保留。", "The original changed. Your input is retained.")
                 : draft.isDirty ? edText("有未应用的修改", "Unapplied changes") : edText("已保存", "Saved"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(edText("重新载入", "Reload")) { reload() }
                    .disabled(unavailable || (!draft.isDirty && !conflict))
                    .accessibilityIdentifier("eda.inspector.reload")
                Spacer(minLength: 8)
                Button(saveTitle) { submit(edits) }
                    .buttonStyle(.borderedProminent)
                    .disabled(unavailable || conflict || !draft.isDirty)
                    .accessibilityIdentifier("eda.inspector.apply")
            }
            if duplicate != nil || delete != nil {
                HStack {
                    if let duplicate {
                        Button(edText("复制", "Duplicate")) { submit(duplicate) }
                            .disabled(unavailable || conflict || draft.isDirty)
                            .help(edText("先应用修改再复制。", "Apply changes before duplicating."))
                    }
                    Spacer(minLength: 8)
                    if let delete {
                        Button(edText("删除", "Delete"), role: .destructive) { submit(delete) }
                            .disabled(unavailable || conflict || deleteLocked(draft.value, session.project))
                            .accessibilityIdentifier("eda.inspector.delete")
                    }
                }.buttonStyle(.bordered)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
    private func submit(_ operation: (Value, EDAProject) throws -> [EDAEdit]) {
        guard !unavailable else { return }
        guard !conflict else { draft.reject(); return }
        do {
            let operations = try operation(draft.value, session.project)
            guard !operations.isEmpty else { return }
            let expected = draft.revision
            working = true
            Task { @MainActor in
                defer { working = false }
                do {
                    try await session.apply(operations, expectedRevision: expected)
                    if let value = source(session.project) { draft.reload(value, revision: session.revision) }
                } catch {
                    if session.conflictWithOriginal || session.revision != expected { draft.reject() }
                    session.report(error)
                }
            }
        } catch { session.report(error) }
    }
    private func reload() {
        guard !unavailable else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                if session.conflictWithOriginal { try await session.refresh(discardChanges: true) }
                if let value = source(session.project) { draft.reload(value, revision: session.revision) }
            } catch { session.report(error) }
        }
    }
}

struct EDInspectorNetPicker: View {
    let session: EDWorkbenchSession
    @Binding var netID: String
    private var nets: [EDANet] { (try? session.netlist().nets) ?? [] }
    var body: some View {
        Picker(edText("网络", "Net"), selection: $netID) {
            Text(edText("未连接", "Unconnected")).tag("")
            if !netID.isEmpty && !nets.contains(where: { $0.id == netID }) {
                Text(edText("未解析网络", "Unresolved net")).tag(netID)
            }
            ForEach(nets, id: \.id) { Text($0.name).tag($0.id) }
        }
    }
}

struct EDInspectorCopperLayerPicker: View {
    let title: String
    let board: EDABoard?
    @Binding var layer: String
    var body: some View {
        Picker(title, selection: $layer) {
            if board?.layers.contains(where: { $0.id == layer && $0.kind == .copper }) != true { Text(layer).tag(layer) }
            ForEach(board?.layers.filter { $0.kind == .copper } ?? [], id: \.id) { Text($0.id).tag($0.id) }
        }
    }
}
