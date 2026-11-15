// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Narrative/event command editor: reorder, branch links, parameter editing,
/// validation. Unsupported commands render read-only with originals kept.
public struct NarrativeEditorView: View {
    @ObservedObject public var session: GameEditingSession
    public let path: GameRelativePath
    @Environment(\.gameEditLocale) private var locale

    @State private var narrative: NarrativeDocument?
    @State private var knownCommands: [GameNarrativeCommandSpec] = []
    @State private var editingCommand: CommandIDBox?
    @State private var issue: GameEditIssue?
    @State private var commandSearch = ""
    @State private var selectedLabel: UUID?

    public init(session: GameEditingSession, path: GameRelativePath) {
        self.session = session; self.path = path
    }

    private var binding: GameNarrativeBinding? {
        session.adapter.narrativeBinding(for: path, in: session.baseProject)
    }

    private var validationIssues: [NarrativeDocument.ValidationIssue] {
        narrative?.validationIssues(knownCodes: Set(binding?.knownCommands.map(\.code) ?? [])) ?? []
    }

    public var body: some View {
        Group {
            if let narrative {
                GameEditorAdaptive { _ in
                    expandedEditor(narrative)
                } compact: {
                    List {
                        Section { titleField(narrative) }
                        labelsSection(narrative)
                        commandsSection(narrative, filtered: false)
                        validationSection
                    }
                }
            } else {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(knownCommands) { spec in
                        Button {
                            let command = NarrativeDocument.Command(code: spec.code, parameters: [:])
                            commit({ $0.applyNarrativeEdit { $0.inserting(command, at: $0.commands.count) } },
                                   summary: GameEditCopy("Add \(spec.code)", "添加 \(spec.code)"))
                        } label: {
                            EditText(spec.title)
                        }
                    }
                    Divider()
                    Button {
                        commit({ $0.applyNarrativeEdit { $0.addingLabel(name: "label\($0.labels.count + 1)") } },
                               summary: GameEditCopy("Add label", "添加标签"))
                    } label: {
                        EditText(GameEditCopy("Add label", "添加标签"))
                    }
                } label: {
                    Label { EditText(GameEditCopy("Add", "添加")) } icon: { Image(systemName: "plus") }
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("game.edit.event.add")
            }
        }
        .task(id: path) { await reload() }
        .onReceive(session.objectWillChange) { Task { await reload() } }
        .sheet(item: $editingCommand) { box in
            if let narrative, let command = narrative.commands.first(where: { $0.id == box.id }) {
                CommandEditSheet(session: session, path: path,
                                 command: command, spec: spec(for: command),
                                 knownLabels: narrative.labels)
            }
        }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: issueBinding) {
            Button(role: .cancel) { issue = nil } label: { EditText(.close) }
        } message: {
            Text(issue?.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n") ?? "")
        }
    }

    private var issueBinding: Binding<Bool> {
        Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
    }

    private func spec(for command: NarrativeDocument.Command) -> GameNarrativeCommandSpec? {
        binding?.knownCommands.first(where: { $0.code == command.code })
    }

    // MARK: - Sections

    private func titleField(_ narrative: NarrativeDocument) -> some View {
        TextField(locale == .chinese ? "标题" : "Title", text: Binding(
            get: { narrative.title },
            set: { newValue in
                guard newValue != narrative.title else { return }
                commit({ $0.title = newValue }, summary: GameEditCopy("Rename narrative", "重命名叙事"))
            }))
            .font(.headline)
            .frame(minHeight: 44)
            .accessibilityIdentifier("game.edit.event.title")
    }

    private func expandedEditor(_ narrative: NarrativeDocument) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(locale == .chinese ? "剧情与分支" : "Story & branches")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 12)
                List {
                    Section { titleField(narrative) }
                    Section {
                        Button { selectedLabel = nil } label: {
                            Label(locale == .chinese ? "全部命令" : "All commands", systemImage: "list.bullet")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .listRowBackground(selectedLabel == nil ? Color.accentColor.opacity(0.12) : Color.clear)
                        ForEach(narrative.labels) { label in
                            Button { selectedLabel = label.id } label: {
                                Label(label.name, systemImage: "tag")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .listRowBackground(selectedLabel == label.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                    labelsSection(narrative)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 44)
            }
            .font(.callout)
            .frame(width: 232)
            .background(GameEditorSurfaces.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.edit.event.branches")
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TextField(locale == .chinese ? "搜索命令或内容" : "Search commands or content", text: $commandSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("game.edit.event.search")
                    Text("\(visibleCommands(narrative).count) / \(narrative.commands.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                Divider()
                List {
                    commandsSection(narrative, filtered: true)
                    validationSection
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 44)
            }
            .font(.callout)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.edit.event.expanded")
    }

    private func visibleCommands(_ narrative: NarrativeDocument) -> [(offset: Int, element: NarrativeDocument.Command)] {
        Array(narrative.commands.enumerated()).filter { _, command in
            let matchesLabel = selectedLabel == nil || command.labelID == selectedLabel
            let text = ([command.code, spec(for: command)?.title.text(locale) ?? ""]
                + command.parameters.values.map(\.displayText)).joined(separator: " ")
            return matchesLabel && (commandSearch.isEmpty || text.localizedCaseInsensitiveContains(commandSearch))
        }
    }

    private func labelsSection(_ narrative: NarrativeDocument) -> some View {
        Section {
            ForEach(narrative.labels) { label in
                HStack {
                    Image(systemName: "tag").foregroundStyle(.secondary)
                    TextField(label.name, text: Binding(
                        get: { label.name },
                        set: { newValue in
                            commit({ doc in
                                if let index = doc.labels.firstIndex(where: { $0.id == label.id }) {
                                    doc.labels[index].name = newValue
                                }
                            }, summary: GameEditCopy("Rename label", "重命名标签"))
                        }))
                    Spacer()
                    EditButton {
                        commit({ $0.applyNarrativeEdit { $0.removingLabel(id: label.id) } },
                               summary: GameEditCopy("Remove label", "删除标签"))
                    } label: { Image(systemName: "trash").foregroundStyle(.red) }
                }
                .frame(minHeight: 44)
            }
        } header: {
            EditText(GameEditCopy("Branch labels", "分支标签"))
        }
    }

    private func commandsSection(_ narrative: NarrativeDocument, filtered: Bool) -> some View {
        let commands = filtered ? visibleCommands(narrative) : Array(narrative.commands.enumerated())
        return Section {
            ForEach(commands, id: \.element.id) { index, command in
                CommandRow(command: command, labelName: narrative.label(id: command.labelID)?.name,
                           index: index, count: narrative.commands.count,
                           locale: locale, spec: spec(for: command),
                           onMoveUp: index > 0 ? {
                               commit({ $0.applyNarrativeEdit { $0.moving(id: command.id, toIndex: index - 1) } },
                                      summary: GameEditCopy("Move command", "移动命令"))
                           } : nil,
                           onMoveDown: index < narrative.commands.count - 1 ? {
                               commit({ $0.applyNarrativeEdit { $0.moving(id: command.id, toIndex: index + 1) } },
                                      summary: GameEditCopy("Move command", "移动命令"))
                           } : nil)
                    .frame(minHeight: 44)
                    .listRowInsets(.init(top: 2, leading: 12, bottom: 2, trailing: 8))
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("game.edit.event.row.\(index)")
                    .onTapGesture {
                        if command.isSupported { editingCommand = CommandIDBox(id: command.id) }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            commit({ $0.applyNarrativeEdit { $0.removing(id: command.id) } },
                                   summary: GameEditCopy("Remove command", "删除命令"))
                        } label: { EditText(.deleted) }
                    }
            }
            .onMove { source, destination in
                // Filtered rows retain their original indices; native drag
                // reordering is only unambiguous for the complete sequence.
                guard !filtered || (selectedLabel == nil && commandSearch.isEmpty) else { return }
                guard let sourceIndex = source.first,
                      narrative.commands.indices.contains(sourceIndex) else { return }
                let id = narrative.commands[sourceIndex].id
                commit({ $0.applyNarrativeEdit { $0.moving(id: id, toIndex: destination) } },
                       summary: GameEditCopy("Move command", "移动命令"))
            }
            if commands.isEmpty {
                Text(locale == .chinese ? "没有匹配的命令" : "No matching commands")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            EditText(GameEditCopy("Commands", "命令"))
        } footer: {
            if narrative.commands.contains(where: { !$0.isSupported }) {
                EditText(GameEditCopy("Grayed commands are not supported by the adapter; their original content is preserved unchanged.",
                                      "灰色命令不受适配器支持；原始内容会原样保留。"))
                    .font(.caption)
            }
        }
    }

    private var validationSection: some View {
        Section {
            ForEach(validationIssues) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .unsupportedCommandPresent ? "info.circle" : "exclamationmark.triangle")
                        .foregroundStyle(item.kind == .unsupportedCommandPresent ? Color.secondary : Color.orange)
                    EditText(item.message)
                        .font(.callout)
                }
                .frame(minHeight: 44)
            }
        } header: {
            EditText(GameEditCopy("Validation", "校验"))
        }
    }

    // MARK: - Commit / reload

    private func commit(_ transform: @escaping (inout NarrativeDocument) -> Void,
                        summary: GameEditCopy) {
        Task {
            do {
                try await session.editNarrativeDocument(at: path, binding: binding, summary: summary, transform)
                await reload()
            } catch let error as GameEditIssue {
                issue = error
            } catch {
                issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                    message: GameEditCopy(String(describing: error), String(describing: error)))])
            }
        }
    }

    private func decode(_ bytes: Data) throws -> NarrativeDocument {
        if let binding { return try binding.decode(bytes) }
        return try NarrativeDocument.decode(bytes)
    }

    private func reload() async {
        knownCommands = binding?.knownCommands ?? []
        do {
            let bytes = try await session.documentBytes(at: path)
            let decoded = try decode(bytes)
            if decoded != narrative { narrative = decoded }
            if let selectedLabel, !decoded.labels.contains(where: { $0.id == selectedLabel }) { self.selectedLabel = nil }
        } catch {
            issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy("These events could not be opened. The original file is kept; open it in the IDE or ask AI to inspect it.",
                                      "无法打开这些事件。原文件已保留，可打开 IDE 或让 AI 检查。"), path: path)])
        }
    }
}

extension NarrativeDocument {
    /// Applies a value-style edit (insert/remove/move/labels) in-place so
    /// session transforms stay concise.
    mutating func applyNarrativeEdit(_ transform: (NarrativeDocument) -> NarrativeDocument) {
        self = transform(self)
    }
}

private struct CommandIDBox: Identifiable, Hashable {
    var id: UUID
}

private struct CommandRow: View {
    let command: NarrativeDocument.Command
    let labelName: String?
    let index: Int
    let count: Int
    let locale: GameEditLocale
    let spec: GameNarrativeCommandSpec?
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(command.isSupported ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .lineLimit(1)
                    if command.branchRole != .none {
                        Text(branchText)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.cyan.opacity(0.15), in: Capsule())
                            .foregroundStyle(.cyan)
                    }
                    if let labelName, command.branchRole != .none || command.labelID != nil {
                        Text(labelName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !command.parameters.isEmpty, command.isSupported {
                    Text(parameterSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !command.isSupported {
                    Text(locale == .chinese ? "不支持 · 只读保留" : "Unsupported · kept read-only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if command.isSupported {
                HStack(spacing: 0) {
                    moveButton(systemName: "chevron.up", action: onMoveUp, enabled: index > 0)
                    moveButton(systemName: "chevron.down", action: onMoveDown, enabled: index < count - 1)
                }
            }
        }
        .opacity(command.isSupported ? 1 : 0.65)
    }

    @ViewBuilder
    private func moveButton(systemName: String, action: (() -> Void)?, enabled: Bool) -> some View {
        if let action, enabled {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(systemName == "chevron.up"
                ? (locale == .chinese ? "上移命令" : "Move command up")
                : (locale == .chinese ? "下移命令" : "Move command down"))
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var iconName: String {
        if !command.isSupported { return "questionmark.square.dashed" }
        switch command.branchRole {
        case .open: return "arrow.turn.down.right"
        case .close: return "arrow.turn.up.left"
        case .none: return "text.bubble"
        }
    }

    private var displayTitle: String {
        spec?.title.text(locale) ?? command.code
    }

    private var branchText: String {
        switch command.branchRole {
        case .open: return locale == .chinese ? "分支开始" : "Branch open"
        case .close: return locale == .chinese ? "分支结束" : "Branch close"
        case .none: return ""
        }
    }

    private var parameterSummary: String {
        if let spec, !spec.fields.isEmpty {
            return spec.fields.compactMap { field in
                let key = field.path.components.last.flatMap { component -> String? in
                    if case .key(let key) = component { return key }; return nil
                } ?? field.id
                guard let value = command.parameters[key] else { return nil }
                return field.label.text(locale) + ": " + value.displayText
            }.joined(separator: "  ·  ")
        }
        var parts: [String] = []
        for key in command.parameters.keys.sorted() {
            let value = command.parameters[key] ?? .null
            parts.append(key + "=" + value.displayText)
        }
        return parts.joined(separator: "  ")
    }
}

private struct CommandEditSheet: View {
    @ObservedObject var session: GameEditingSession
    let path: GameRelativePath
    @State var command: NarrativeDocument.Command
    let spec: GameNarrativeCommandSpec?
    let knownLabels: [NarrativeDocument.Label]
    @State private var saveError: String?
    @Environment(\.gameEditLocale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        EditText(GameEditCopy("Command", "命令"))
                        Spacer()
                        Text(command.code).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                if let spec, !spec.fields.isEmpty {
                    Section {
                        ForEach(spec.fields) { field in
                            HStack {
                                EditText(field.label)
                                Spacer()
                                parameterControl(field)
                                    .frame(maxWidth: 240)
                                    .accessibilityIdentifier("game.edit.event.field." + parameterKey(field))
                            }
                            .frame(minHeight: 44)
                        }
                    } header: {
                        EditText(GameEditCopy("Parameters", "参数"))
                    }
                } else {
                    Section {
                        ForEach(Array(command.parameters.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                Spacer()
                                Text(command.parameters[key]?.displayText ?? "")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    } header: {
                        EditText(GameEditCopy("Parameters (read-only binding)", "参数（只读绑定）"))
                    }
                }
                Section {
                    Picker(selection: Binding<UUID?>(
                        get: { command.labelID },
                        set: { newValue in command.labelID = newValue })) {
                        Text(locale == .chinese ? "无链接" : "No link").tag(UUID?.none)
                        ForEach(knownLabels) { label in
                            Text(label.name).tag(Optional(label.id))
                        }
                    } label: {
                        EditText(GameEditCopy("Branch link", "分支链接"))
                    }
                    .frame(minHeight: 44)
                    Picker(selection: $command.branchRole) {
                        Text("—").tag(NarrativeDocument.BranchRole.none)
                        Text(locale == .chinese ? "开始" : "Open").tag(NarrativeDocument.BranchRole.open)
                        Text(locale == .chinese ? "结束" : "Close").tag(NarrativeDocument.BranchRole.close)
                    } label: {
                        EditText(GameEditCopy("Branch role", "分支角色"))
                    }
                    .frame(minHeight: 44)
                } header: {
                    EditText(GameEditCopy("Branch", "分支"))
                }
            }
            .navigationTitle(spec?.title.text(locale) ?? command.code)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    EditButton { dismiss() } label: { EditText(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    EditButton {
                        Task {
                            do {
                                let updated = command
                                // A native binding retains the bytes read by
                                // decode. Use that same instance for encode.
                                let binding = session.adapter.narrativeBinding(for: path, in: session.baseProject)
                                try await session.editDocument(at: path,
                                    summary: GameEditCopy("Edit \(command.code)", "编辑 \(command.code)")) { bytes in
                                    let decoded: NarrativeDocument
                                    if let binding {
                                        decoded = try binding.decode(bytes)
                                    } else {
                                        decoded = try NarrativeDocument.decode(bytes)
                                    }
                                    guard let current = decoded.commands.first(where: { $0.id == updated.id }),
                                          current.originalPayload == updated.originalPayload else { throw GameProjectError.invalidEdit }
                                    let edited = decoded.updating(id: updated.id) { $0 = updated }
                                    if let binding {
                                        return try binding.encode(edited)
                                    }
                                    return try edited.encode()
                                }
                                dismiss()
                            } catch { saveError = String(describing: error) }
                        }
                    } label: { EditText(.save) }
                    .accessibilityIdentifier("game.edit.event.save")
                }
            }
        }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button { saveError = nil } label: { EditText(.close) }
        } message: { Text(saveError ?? "") }
    }

    @ViewBuilder private func parameterControl(_ field: GameParameterField) -> some View {
        let key = parameterKey(field)
        switch field.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { command.parameters[key]?.boolValue ?? false }, set: { command.parameters[key] = .bool($0) })).labelsHidden()
        case .integer:
            TextField(valuePlaceholder(field), value: Binding(get: { command.parameters[key]?.intValue ?? 0 }, set: { command.parameters[key] = .number(Double($0)) }), format: .number).multilineTextAlignment(.trailing)
        case .decimal:
            TextField(valuePlaceholder(field), value: Binding(get: { command.parameters[key]?.numberValue ?? 0 }, set: { command.parameters[key] = .number($0) }), format: .number).multilineTextAlignment(.trailing)
        case .choice(let options):
            Picker("", selection: Binding(get: { command.parameters[key]?.stringValue ?? options.first ?? "" }, set: { command.parameters[key] = .string($0) })) { ForEach(options, id: \.self) { Text($0).tag($0) } }.labelsHidden()
        case .text:
            TextField(valuePlaceholder(field), text: Binding(get: { command.parameters[key]?.stringValue ?? "" }, set: { command.parameters[key] = .string($0) })).multilineTextAlignment(.trailing)
        case .multiline:
            TextEditor(text: Binding(get: { command.parameters[key]?.stringValue ?? "" }, set: { command.parameters[key] = .string($0) }))
                .frame(minHeight: 88, maxHeight: 220)
        }
    }

    private func parameterKey(_ field: GameParameterField) -> String {
        field.path.components.last.flatMap { component in
            if case .key(let key) = component { return key }
            return nil
        } ?? field.id
    }

    private func valuePlaceholder(_ field: GameParameterField) -> String {
        field.placeholder ?? (locale == .chinese ? "未设置" : "Not set")
    }
}
