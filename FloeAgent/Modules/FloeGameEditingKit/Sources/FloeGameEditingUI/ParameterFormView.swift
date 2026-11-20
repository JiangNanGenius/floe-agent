// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Schema-driven character/item parameter form over a project JSON document.
public struct ParameterFormView: View {
    @ObservedObject public var session: GameEditingSession
    public let path: GameRelativePath
    @Environment(\.gameEditLocale) private var locale
    @State private var document: ParameterDocument?
    @State private var fieldValues: [String: JSONValue] = [:]
    @State private var issue: GameEditIssue?
    @State private var recordSchemas: [GameParameterSchema] = []
    @State private var selectedRecord: String?
    @State private var reloadGeneration = 0
    @State private var recordSearch = ""
    @State private var numericInput: [String: String] = [:]
    @FocusState private var focusedField: String?

    public init(session: GameEditingSession, path: GameRelativePath) {
        self.session = session; self.path = path
    }

    private var schemas: [GameParameterSchema] {
        recordSchemas.isEmpty ? session.adapter.parameterSchemas(for: path, in: session.baseProject) : recordSchemas
    }

    /// Engine-owned codec for binary/native parameter documents. Nil means
    /// the file is plain JSON bytes.
    private var binding: GameParameterBinding? {
        session.adapter.parameterBinding(for: path, in: session.baseProject)
    }

    public var body: some View {
        Group {
            if let document {
                GameEditorAdaptive { width in
                    expandedForm(document, width: width)
                } compact: {
                    compactForm(document)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: path) { await reload() }
        .onSubmit { focusedField = nil }
        .onChange(of: focusedField) { old, _ in
            if let old { numericInput[old] = nil }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField != nil {
                    Spacer()
                    Button(GameEditCopy("Done", "完成输入").text(locale)) { focusedField = nil }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("game.edit.parameter.finishInput")
                }
            }
        }
        #endif
        .onReceive(session.objectWillChange) { Task { await reload() } }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: issueBinding) {
            Button(role: .cancel) { issue = nil } label: { EditText(.close) }
        } message: {
            Text(issue?.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n") ?? "")
        }
    }

    private func compactForm(_ document: ParameterDocument) -> some View {
        Form {
                    if schemas.count > 1 {
                        Picker(selection: $selectedRecord) {
                            ForEach(schemas) { schema in EditText(schema.title).tag(Optional(schema.id)) }
                        } label: { EditText(GameEditCopy("Record", "条目")) }
                        .accessibilityIdentifier("game.edit.parameter.record")
                    }
                    ForEach(schemas.filter { schemas.count == 1 || $0.id == selectedRecord }) { schema in
                        Section {
                            ForEach(schema.fields) { field in
                                fieldRow(field, root: document.root)
                            }
                        } header: {
                            EditText(schema.title)
                        }
                    }
                    Section {
                        HStack {
                            EditText(GameEditCopy("Other parameters and custom content are kept.",
                                                  "其他参数和自定义内容会保留。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
        }
    }

    private func expandedForm(_ document: ParameterDocument, width: CGFloat) -> some View {
        let sidebarWidth: CGFloat = width < 1_000 ? 208 : 232
        let detailWidth = width - sidebarWidth - 1
        let count = detailWidth >= 980 ? 3 : detailWidth >= 540 ? 2 : 1
        let columns = Array(repeating: GridItem(.flexible(minimum: 220), spacing: 16), count: count)
        return HStack(spacing: 0) {
            recordList(document)
                .frame(width: sidebarWidth)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(selectedSchema.map { recordName($0, document: document) } ?? "")
                            .font(.headline).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(selectedIndex.map { $0 + 1 } ?? 0) / \(schemas.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        recordStep(-1)
                        recordStep(1)
                    }
                    Divider()
                    if let schema = selectedSchema {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                            ForEach(schema.fields.filter { !isMultiline($0) }) { field in
                                fieldRow(field, root: document.root)
                                    .padding(.horizontal, 4)
                                    .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("game.edit.parameter.properties")
                        ForEach(schema.fields.filter { isMultiline($0) }) { field in
                            fieldRow(field, root: document.root)
                        }
                    }
                    EditText(GameEditCopy("Other parameters and custom content are kept.",
                                          "其他参数和自定义内容会保留。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(12)
            }
            .accessibilityIdentifier("game.edit.parameter.detail")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.edit.parameter.expanded")
    }

    private var selectedSchema: GameParameterSchema? {
        schemas.first { $0.id == selectedRecord } ?? schemas.first
    }

    private var selectedIndex: Int? {
        schemas.firstIndex { $0.id == selectedSchema?.id }
    }

    private func isMultiline(_ field: GameParameterField) -> Bool {
        if case .multiline = field.kind { return true }; return false
    }

    private func recordName(_ schema: GameParameterSchema, document: ParameterDocument) -> String {
        if let field = schema.fields.first(where: { $0.id.hasSuffix(".name") }),
           let name = field.path.lookup(in: document.root)?.stringValue, !name.isEmpty {
            return name
        }
        return schema.title.text(locale)
    }

    private func recordList(_ document: ParameterDocument) -> some View {
        let filtered = schemas.filter {
            recordSearch.isEmpty || recordName($0, document: document).localizedCaseInsensitiveContains(recordSearch)
                || $0.title.text(locale).localizedCaseInsensitiveContains(recordSearch)
        }
        return VStack(spacing: 0) {
            HStack {
                Text(GameEditCopy("Records", "条目").text(locale)).font(.subheadline.bold())
                Spacer()
                Text("\(schemas.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).frame(height: 36)
            TextField(GameEditCopy("Search records", "搜索条目").text(locale), text: $recordSearch)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .padding(.horizontal, 10)
                .accessibilityIdentifier("game.edit.parameter.recordSearch")
            List(selection: $selectedRecord) {
                ForEach(filtered) { schema in
                    Button { selectedRecord = schema.id } label: {
                        HStack(spacing: 8) {
                            Text("\((schemas.firstIndex { $0.id == schema.id } ?? 0) + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(recordName(schema, document: document))
                                .font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(schema.id)
                    .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowBackground(selectedSchema?.id == schema.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    .accessibilityIdentifier("game.edit.parameter.record." + schema.id)
                }
                if filtered.isEmpty {
                    Text(GameEditCopy("No matching records", "没有匹配的条目").text(locale))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
        }
        .background(GameEditorSurfaces.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.edit.parameter.records")
    }

    private func recordStep(_ offset: Int) -> some View {
        Button {
            guard let index = selectedIndex, schemas.indices.contains(index + offset) else { return }
            selectedRecord = schemas[index + offset].id
        } label: {
            Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(offset < 0
            ? (GameEditCopy("Previous record", "上一条").text(locale))
            : (GameEditCopy("Next record", "下一条").text(locale)))
        .accessibilityIdentifier(offset < 0 ? "game.edit.parameter.previous" : "game.edit.parameter.next")
        .disabled(selectedIndex.map { !schemas.indices.contains($0 + offset) } ?? true)
    }

    private var issueBinding: Binding<Bool> {
        Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
    }

    @ViewBuilder
    private func fieldRow(_ field: GameParameterField, root: JSONValue) -> some View {
        let value = fieldValues[field.id] ?? field.path.lookup(in: root) ?? .null
        switch field.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value.boolValue ?? false }, set: { newValue in
                guard newValue != (value.boolValue ?? false) else { return }
                commit(field, value: .bool(newValue))
            })) { EditText(field.label) }
            .frame(minHeight: 44)
            .accessibilityIdentifier("game.edit.parameter." + field.id)
        case .choice(let options):
            Picker(selection: Binding(get: { value.stringValue ?? options.first ?? "" }, set: { newValue in
                guard newValue != (value.stringValue ?? options.first ?? "") else { return }
                commit(field, value: .string(newValue))
            })) {
                ForEach(options, id: \.self) { option in Text(option).tag(option) }
            } label: {
                EditText(field.label)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("game.edit.parameter." + field.id)
        case .integer:
            HStack {
                EditText(field.label)
                Spacer()
                TextField(valuePlaceholder(field), text: Binding<String>(
                    get: { numericInput[field.id] ?? value.intValue.map(String.init) ?? "" },
                    set: { newValue in
                        guard focusedField == field.id else { return }
                        numericInput[field.id] = newValue
                        guard let number = Int(newValue), number != value.intValue else { return }
                        fieldValues[field.id] = .number(Double(number))
                        commit(field, value: .number(Double(number)))
                    }))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field.id)
                    .frame(maxWidth: 140, minHeight: 44)
                    .accessibilityIdentifier("game.edit.parameter." + field.id)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focusedField = field.id })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.edit.parameter.row." + field.id)
        case .decimal:
            HStack {
                EditText(field.label)
                Spacer()
                TextField(valuePlaceholder(field), text: Binding<String>(
                    get: { numericInput[field.id] ?? value.numberValue.map { String($0) } ?? "" },
                    set: { newValue in
                        guard focusedField == field.id else { return }
                        numericInput[field.id] = newValue
                        guard let number = Double(newValue), number != value.numberValue else { return }
                        fieldValues[field.id] = .number(number)
                        commit(field, value: .number(number))
                    }))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field.id)
                    .frame(maxWidth: 140, minHeight: 44)
                    .accessibilityIdentifier("game.edit.parameter." + field.id)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focusedField = field.id })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.edit.parameter.row." + field.id)
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                EditText(field.label)
                TextEditor(text: Binding<String>(
                    get: { fieldValues[field.id]?.stringValue ?? value.stringValue ?? "" },
                    set: { newValue in
                        guard newValue != (fieldValues[field.id]?.stringValue ?? value.stringValue ?? "") else { return }
                        fieldValues[field.id] = .string(newValue); commit(field, value: .string(newValue))
                    }))
                    .frame(minHeight: 88)
                    .accessibilityIdentifier("game.edit.parameter." + field.id)
            }
            .frame(minHeight: 44)
        case .text:
            HStack {
                EditText(field.label)
                Spacer()
                TextField(valuePlaceholder(field), text: Binding<String>(
                    get: { fieldValues[field.id]?.stringValue ?? value.stringValue ?? "" },
                    set: { newValue in
                        guard newValue != (fieldValues[field.id]?.stringValue ?? value.stringValue ?? "") else { return }
                        fieldValues[field.id] = .string(newValue); commit(field, value: .string(newValue))
                    }))
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field.id)
                    .submitLabel(.done)
                    .frame(maxWidth: 220, minHeight: 44)
                    .accessibilityIdentifier("game.edit.parameter." + field.id)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focusedField = field.id })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.edit.parameter.row." + field.id)
        }
    }

    private func valuePlaceholder(_ field: GameParameterField) -> String {
        field.placeholder ?? (GameEditCopy("Not set", "未设置").text(locale))
    }

    /// Text edits enter the session immediately, including multiline text;
    /// Save never depends on Return being pressed in a text editor first.
    private func commit(_ field: GameParameterField, value: JSONValue) {
        Task {
            do {
                try await session.editParameterDocument(at: path, binding: binding,
                                                        schema: schemaFor(field),
                    summary: GameEditCopy("Set \(field.label.en)", "设置\(field.label.zh)")) { document in
                    try document.set(value, for: field)
                }
                if fieldValues[field.id] == value { fieldValues[field.id] = nil }
                await reload()
            } catch let error as GameEditIssue {
                issue = error
            } catch {
                issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                    message: GameEditCopy(String(describing: error), String(describing: error)))])
            }
        }
    }

    private func schemaFor(_ field: GameParameterField) -> GameParameterSchema {
        schemas.first { $0.fields.contains(field) } ?? schemas[0]
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        guard let schema = session.adapter.parameterSchemas(for: path, in: session.baseProject).first else { return }
        do {
            let loaded = try await session.parameterDocument(at: path, binding: binding, schema: schema)
            guard generation == reloadGeneration else { return }
            document = loaded
            if let document {
                recordSchemas = try session.adapter.parameterSchemas(for: path, json: document.serialized(), in: session.baseProject)
                if !recordSchemas.contains(where: { $0.id == selectedRecord }) { selectedRecord = recordSchemas.first?.id }
            }
            issue = nil
        } catch {
            guard generation == reloadGeneration else { return }
            issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy("The parameter codec could not read this file; original bytes are untouched.",
                                      "参数编解码器无法读取此文件；原始字节未改动。"), path: path)])
        }
    }
}
