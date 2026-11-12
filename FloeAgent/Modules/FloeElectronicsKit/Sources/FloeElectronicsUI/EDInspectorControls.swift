// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Observation
import FloeElectronicsCore

struct EDInspectorDraftKey: Hashable, Sendable {
    let projectID: UUID
    let context: EDADocumentContext?
    let objectID: UUID
    let valueType: String
}

/// Draft ownership scoped to one workbench presentation. Entries are retained
/// across inline/sheet and width-class changes, never applied automatically,
/// and bounded so a long editing session cannot grow without limit.
@Observable
final class EDInspectorDraftStore: @unchecked Sendable {
    // Bindings are created from SwiftUI/main-actor views; the box itself is
    // never shared with a background worker. The revision keeps the Apply
    // state and dirty indicator in sync with nested edits.
    private final class Box<Value: Equatable & Sendable>: @unchecked Sendable {
        var draft: EDInspectorDraft<Value>
        init(_ draft: EDInspectorDraft<Value>) { self.draft = draft }
    }

    private(set) var revision: UInt64 = 0
    private var entries: [EDInspectorDraftKey: Any] = [:]
    private var order: [EDInspectorDraftKey] = []
    private let capacity: Int

    init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    func binding<Value: Equatable & Sendable>(for key: EDInspectorDraftKey,
                                              initial: EDInspectorDraft<Value>) -> Binding<EDInspectorDraft<Value>> {
        let box: Box<Value>
        if let existing = entries[key] as? Box<Value> {
            box = existing
        } else {
            box = Box(initial)
            entries[key] = box
            order.append(key)
            while entries.count > capacity, let oldest = order.first {
                entries[oldest] = nil
                order.removeFirst()
            }
        }
        return Binding(get: { box.draft }, set: { box.draft = $0; self.revision &+= 1 })
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        revision &+= 1
    }

    var count: Int { entries.count }
}

private struct EDInspectorDraftStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: EDInspectorDraftStore? = nil
}

extension EnvironmentValues {
    var edInspectorDraftStore: EDInspectorDraftStore? {
        get { self[EDInspectorDraftStoreEnvironmentKey.self] }
        set { self[EDInspectorDraftStoreEnvironmentKey.self] = newValue }
    }
}

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
                .frame(height: 96)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
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
    let initialValue: Value
    let initialRevision: UInt64
    let draftKey: EDInspectorDraftKey?
    @Environment(\.edInspectorDraftStore) private var sharedDraftStore
    @State private var localDraft: EDInspectorDraft<Value>
    @State private var localStore = EDInspectorDraftStore()
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
        initialValue = value; initialRevision = session.revision
        if let objectID = Self.objectID(of: value) {
            draftKey = .init(projectID: session.project.id, context: session.selection.context,
                             objectID: objectID, valueType: String(describing: Value.self))
        } else {
            draftKey = nil
        }
        self.content = content
        _localDraft = State(initialValue: .init(value, revision: session.revision))
    }

    private static func objectID(of value: Value) -> UUID? {
        if let value = value as? EDComponentInspectorValue { return value.placement.id }
        if let value = value as? EDABus { return value.id }
        if let value = value as? EDABusEntry { return value.id }
        if let value = value as? EDAFootprint { return value.id }
        if let value = value as? EDATrack { return value.id }
        if let value = value as? EDAVia { return value.id }
        if let value = value as? EDAHole { return value.id }
        if let value = value as? EDAZone { return value.id }
        if let value = value as? EDABoard { return value.id }
        if let value = value as? EDASymbolDefinition { return value.id }
        if let value = value as? EDAFootprintDefinition { return value.id }
        return nil
    }

    /// The same binding is returned for the same selected object while the
    /// workbench store lives, including when this view is rebuilt after an
    /// inline/side-panel or sheet presentation change.
    private var draft: Binding<EDInspectorDraft<Value>> {
        if let draftKey {
            let store = sharedDraftStore ?? localStore
            _ = store.revision
            return store.binding(for: draftKey, initial: .init(initialValue, revision: initialRevision))
        }
        return $localDraft
    }

    private var unavailable: Bool { working || session.busy || session.isClosed || session.isRouting || session.isFilling }
    private var conflict: Bool {
        draft.wrappedValue.needsReload || draft.wrappedValue.revision != session.revision || session.conflictWithOriginal
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content(draft.value).disabled(unavailable)
            }.padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .onChange(of: session.revision, initial: true) { _, revision in
            guard !working, let value = source(session.project) else { return }
            draft.wrappedValue.receive(value, revision: revision)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(conflict
                     ? edText("原件已更改。你的输入仍保留。", "The original changed. Your input is retained.")
                     : draft.wrappedValue.isDirty ? edText("有未应用的修改", "Unapplied changes") : edText("已保存", "Saved"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(edText("重新载入", "Reload")) { reload() }
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .disabled(unavailable || (!draft.wrappedValue.isDirty && !conflict))
                    .accessibilityIdentifier("eda.inspector.reload")
                Button(saveTitle) { submit(edits) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .disabled(unavailable || conflict || !draft.wrappedValue.isDirty)
                    .accessibilityIdentifier("eda.inspector.apply")
            }
            if duplicate != nil || delete != nil {
                HStack(spacing: 6) {
                    if let duplicate {
                        Button(edText("复制", "Duplicate")) { submit(duplicate) }
                            .controlSize(.small)
                            .frame(minHeight: 44)
                            .disabled(unavailable || conflict || draft.wrappedValue.isDirty)
                            .help(edText("先应用修改再复制。", "Apply changes before duplicating."))
                    }
                    Spacer(minLength: 4)
                    if let delete {
                        Button(edText("删除", "Delete"), role: .destructive) { submit(delete) }
                            .controlSize(.small)
                            .frame(minHeight: 44)
                            .disabled(unavailable || conflict || deleteLocked(draft.wrappedValue.value, session.project))
                            .accessibilityIdentifier("eda.inspector.delete")
                    }
                }.buttonStyle(.bordered)
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }

    private func submit(_ operation: (Value, EDAProject) throws -> [EDAEdit]) {
        guard !unavailable else { return }
        guard !conflict else { draft.wrappedValue.reject(); return }
        do {
            let operations = try operation(draft.wrappedValue.value, session.project)
            guard !operations.isEmpty else { return }
            let expected = draft.wrappedValue.revision
            working = true
            Task { @MainActor in
                defer { working = false }
                do {
                    try await session.apply(operations, expectedRevision: expected)
                    if let value = source(session.project) { draft.wrappedValue.reload(value, revision: session.revision) }
                } catch {
                    if session.conflictWithOriginal || session.revision != expected { draft.wrappedValue.reject() }
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
                if let value = source(session.project) { draft.wrappedValue.reload(value, revision: session.revision) }
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
