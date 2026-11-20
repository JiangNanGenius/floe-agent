// SPDX-License-Identifier: MPL-2.0
import SwiftUI

@MainActor
final class MacSearchSettings: ObservableObject {
    let access: MacSearchAccess
    let entries: [SearchProviderCatalogEntry]
    @Published private(set) var rows: [WebSearchProviderInstance] = []
    @Published private(set) var readFailure: String?

    init(namespace: String, useKeychain: Bool, preferences: UserDefaults = .standard) {
        access = MacSearchAccess(namespace: namespace, useKeychain: useKeychain, preferences: preferences)
        entries = (SearchProviderCatalogIndex.loadBundled()?.entries ?? []).filter { MacSearchAccess.supported($0.supportedAdapter) }
        reload()
    }

    func reload() {
        do { rows = try access.instances(); readFailure = nil }
        catch { readFailure = error.localizedDescription }
    }
}

struct MacSearchSettingsView: View {
    @ObservedObject var settings: MacSearchSettings
    @Environment(\.locale) private var locale
    @State private var editor: MacSearchDraft?
    @State private var delete: WebSearchProviderInstance?
    @State private var message: String?
    private var language: String { locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en" }
    private func t(_ en: String, _ zh: String) -> String { language == "en" ? en : zh }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("mac.settings.webSearch").font(.headline)
                Spacer()
                Menu {
                    ForEach(settings.entries) { entry in
                        Button(entry.displayName(localePrimary: language)) {
                            if let row = SearchProviderDraftFactory.draftInstance(for: entry, localePrimary: language) {
                                editor = MacSearchDraft(instance: row, entry: entry, isNew: true)
                            }
                        }
                    }
                } label: { Label(t("Add provider", "添加供应商"), systemImage: "plus") }
                .fixedSize().disabled(settings.entries.isEmpty || settings.readFailure != nil)
                .accessibilityIdentifier("settings.search.add")
            }.padding()
            Divider()
            if let error = settings.readFailure ?? message { Text(error).font(.callout).foregroundStyle(.red).padding() }
            if settings.rows.isEmpty {
                ContentUnavailableView(t("No search providers", "尚无搜索供应商"), systemImage: "magnifyingglass",
                    description: Text(settings.entries.isEmpty ? t("The search catalog could not be loaded.", "无法载入搜索供应商目录。") :
                        t("Add and enable a provider to search the web in conversations.", "添加并启用供应商后，可以在会话中搜索网页。")))
            } else {
                List {
                    ForEach(settings.rows) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.configuration.displayName)
                                if let entry = catalog(for: row) {
                                    Text(entry.displayName(localePrimary: language)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle(t("Enabled", "启用"), isOn: Binding(get: { row.configuration.enabled }, set: { flag in
                                change { try settings.access.change(row.id, enable: flag) }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Menu {
                                Button(t("Edit…", "编辑…")) {
                                    if let entry = catalog(for: row) { editor = MacSearchDraft(instance: row, entry: entry, isNew: false) }
                                }
                                Button(t("Move up", "上移")) { change { try settings.access.change(row.id, moveUp: true) } }
                                    .disabled(settings.rows.first?.id == row.id)
                                Divider()
                                Button(t("Remove…", "移除…"), role: .destructive) { delete = row }
                            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(t("Provider actions", "供应商操作")) }
                            .menuStyle(.borderlessButton).fixedSize()
                        }.padding(.vertical, 3)
                    }
                }
                Text(t("Search tries enabled providers in this order.", "搜索按此顺序使用已启用的供应商。"))
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
        .accessibilityIdentifier("settings.search")
        .onAppear { settings.reload() }
        .sheet(item: $editor) { draft in
            MacSearchEditor(settings: settings, draft: draft, language: language)
        }
        .confirmationDialog(t("Remove search provider?", "移除此搜索供应商？"), isPresented:
            Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), presenting: delete) { row in
            Button(t("Remove", "移除"), role: .destructive) { change { try settings.access.change(row.id, remove: true) } }
        } message: { row in
            Text(t("The stored key for ", "也将删除此账号的已存密钥 · ") + row.configuration.displayName + (language == "en" ? " will also be removed." : ""))
        }
    }

    private func catalog(for row: WebSearchProviderInstance) -> SearchProviderCatalogEntry? {
        settings.entries.first { $0.presetID == row.presetID }
    }
    private func change(_ body: () throws -> Void) {
        do { try body(); message = nil; settings.reload() } catch { message = error.localizedDescription }
    }
}

private struct MacSearchDraft: Identifiable {
    var instance: WebSearchProviderInstance
    let entry: SearchProviderCatalogEntry
    let isNew: Bool
    var id: UUID { instance.id }
}

private struct MacSearchEditor: View {
    @ObservedObject var settings: MacSearchSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MacSearchDraft
    @State private var fields: [String: String] = [:]
    @State private var query = "Swift"
    @State private var feedback: String?
    @State private var validating = false
    @State private var testTask: Task<Void, Never>?
    private let language: String
    init(settings: MacSearchSettings, draft: MacSearchDraft, language: String) {
        self.settings = settings; self._draft = State(initialValue: draft); self.language = language
    }
    private func t(_ en: String, _ zh: String) -> String { language == "en" ? en : zh }
    private func field(_ key: String) -> Binding<String> {
        .init(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
    }
    private func option(_ key: String, fallback: String) -> Binding<String> {
        .init(get: { draft.instance.configuration.options[key] ?? fallback }, set: { value in
            draft.instance.configuration.options[key] = value
            if key == "interface" { fields = [:] }
        })
    }
    private func switchOption(_ key: String, fallback: String = "false") -> Binding<Bool> {
        let text = option(key, fallback: fallback)
        return .init(get: { text.wrappedValue == "true" }, set: { text.wrappedValue = $0 ? "true" : "false" })
    }
    private var visibleOptions: [SearchProviderCatalogEntry.OptionField] {
        let c = draft.instance.configuration
        return draft.entry.optionFields.filter { item in
            if c.kind == .bochaWeb && item.key == "summaryEnabled" { return false }
            if c.kind == .moonshot && c.options["interface"] == "kimiCode" && item.key == "includeContent" { return false }
            if c.kind == .deepseek && c.options["searchWhileThinking"] == "true" && item.key == "needContent" { return false }
            return true
        }
    }
    private func channelLabel(_ value: String) -> String {
        switch value {
        case "kimiCode": "Kimi Code"
        case "payg": t("Pay as you go", "按量付费")
        case "agentPlan": "Agent Plan"
        case "arkResponses": t("Ark Responses", "方舟 Responses")
        case "doubaoSearch": t("Doubao Search", "豆包搜索")
        case "doubaoCustom": t("Doubao", "豆包")
        case "onlineContent": t("Online content", "联网内容")
        default: value
        }
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text(draft.entry.displayName(localePrimary: language)).font(.headline).padding([.top, .horizontal])
            Form {
                TextField(t("Account name", "账号名称"), text: $draft.instance.configuration.displayName)
                Toggle(t("Enable for conversations", "在会话中启用"), isOn: $draft.instance.configuration.enabled)
                if draft.instance.configuration.kind == .volcengine {
                    Picker(t("Account type", "账号类型"), selection: option("interface", fallback: "agentPlan")) {
                        ForEach(VolcengineSearchInterface.allCases) { item in Text(channelLabel(item.rawValue)).tag(item.rawValue) }
                    }.disabled(!draft.isNew)
                    if draft.instance.configuration.options["interface"] == "arkResponses" {
                        Picker(t("Search engine", "搜索引擎"), selection: option("arkEngine", fallback: "doubaoCustom")) {
                            ForEach(VolcengineArkSearchEngine.allCases) { item in Text(channelLabel(item.rawValue)).tag(item.rawValue) }
                        }
                        TextField(t("Model", "模型"), text: option("arkModel", fallback: VolcengineSearchOptions.defaultArkModel))
                    }
                }
                ForEach(visibleOptions) { item in
                    let label = item.label[language] ?? item.label["en"] ?? item.key
                    switch item.kind {
                    case .bool:
                        Toggle(label, isOn: switchOption(item.key, fallback: item.defaultValue ?? "false"))
                    case .text:
                        TextField(label, text: option(item.key, fallback: item.defaultValue ?? ""))
                    case .option:
                        Picker(label, selection: option(item.key, fallback: item.defaultValue ?? "")) {
                            ForEach(item.allowedValues ?? [], id: \.self) { text in Text(channelLabel(text)).tag(text) }
                        }.disabled(item.key == "interface" && !draft.isNew)
                    }
                }
                ForEach(draft.entry.credentialFields) { item in
                    SecureField(item.label[language] ?? item.label["en"] ?? item.key, text: field(item.key),
                        prompt: Text(draft.isNew ? "" : t("Keep stored value", "保留已存密钥")))
                }
                if let url = WebSearchService.canonicalEndpoint(for: draft.instance.configuration) {
                    LabeledContent(t("Service", "服务地址"), value: url.host ?? url.absoluteString)
                }
                Section {
                    TextField(t("Test query", "测试搜索词"), text: $query)
                    Button(t("Test search", "测试搜索")) { test() }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped).disabled(validating)
            HStack {
                if validating { ProgressView().controlSize(.small) }
                Spacer()
                Button(t("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("Save", "保存")) {
                    do {
                        try settings.access.save(draft.instance, fields: fields, isNew: draft.isNew)
                        settings.reload(); dismiss()
                    } catch { feedback = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(validating)
            }.padding([.bottom, .horizontal])
        }.frame(width: 460, height: 490)
        .onDisappear { testTask?.cancel() }
    }
    private func test() {
        validating = true; feedback = nil
        testTask = Task {
            defer { validating = false }
            do {
                let outcome = try await settings.access.test(draft.instance, fields: fields, query: query)
                try Task.checkCancellation()
                feedback = outcome.error ?? (t("Results returned", "返回结果数") + " · " + String(outcome.results.count))
            } catch { if !Task.isCancelled { feedback = error.localizedDescription } }
        }
    }
}
