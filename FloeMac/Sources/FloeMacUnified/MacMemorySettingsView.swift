// SPDX-License-Identifier: MPL-2.0

import FloeAgentRuntime
import FloeMacSelfCore
import SwiftUI

struct MacMemorySettingsView: View {
    #if FLOE_MAC_HOST_SMOKE
    static var smokeAddFrame: CGRect?
    static var smokeEditorMounted = false
    #endif

    @ObservedObject var workspace: HostAgentWorkspace
    @State private var scope: MemoryScope?
    @State private var entries: [MemoryEntry] = []
    @State private var cursor: String?
    @State private var pending: [DurableMemoryCandidate] = []
    @State private var profiles: [PersonalizationDocumentKind: PersonalizationRetention] = [:]
    @State private var editor: MacMemoryEditor.Draft?
    @State private var deleteEntry: MemoryEntry?
    @State private var request = UUID()
    @State private var busy = false
    @State private var problem: String?

    private var profileWorkspace: UUID? {
        if case .some(.workspace(let id)) = scope { return id }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Picker(t("范围", "Scope"), selection: $scope) {
                    Text(t("全部", "All")).tag(nil as MemoryScope?)
                    Text(t("个人", "Personal")).tag(Optional(MemoryScope.userProfile))
                    Text(t("跨任务", "Across Tasks")).tag(Optional(MemoryScope.agentGlobal))
                    ForEach(workspace.workspaces.filter { $0.kind == .project }) { project in
                        Text(project.name).tag(Optional(MemoryScope.workspace(project.id)))
                    }
                    if let id = workspace.selectedID {
                        Text(t("当前任务", "Current Task")).tag(Optional(MemoryScope.task(id)))
                    }
                }
                Button(t("添加记忆…", "Add Memory…"), systemImage: "plus") {
                    let target = scope ?? .userProfile
                    editor = .init(subject: .entry(original: nil, scope: target), text: "")
                }
                .accessibilityIdentifier("settings.memory.add")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeAddFrame = $0 })
                #endif
            }
            Section(t("已保存", "Saved")) {
                if entries.isEmpty { Text(t("此范围暂无记忆。", "No saved memories in this scope.")).foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.content).lineLimit(4).textSelection(.enabled)
                            Label(scopeName(entry.scope), systemImage: entry.isPinned ? "pin.fill" : "bookmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button(t("编辑…", "Edit…")) {
                                editor = .init(subject: .entry(original: entry, scope: entry.scope), text: entry.content,
                                               pinned: entry.isPinned)
                            }
                            Button(t("删除…", "Delete…"), role: .destructive) { deleteEntry = entry }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(t("记忆操作", "Memory Actions"))
                        .fixedSize()
                    }
                }
                if cursor != nil { Button(t("显示更多", "Show More")) { Task { await load(append: true) } } }
            }
            Section(t("待审核", "For Review")) {
                if pending.isEmpty { Text(t("暂无待审记忆。", "No memories to review.")).foregroundStyle(.secondary) }
                ForEach(pending) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.candidate.content).textSelection(.enabled)
                        Text(scopeName(item.candidate.scope)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(t("保留", "Keep")) { resolve(item.id, keep: true) }
                            Button(t("舍弃", "Discard")) { resolve(item.id, keep: false) }
                        }
                    }
                }
            }
            Section {
                ForEach(PersonalizationDocumentKind.allCases, id: \.self) { kind in
                    let current = profiles[kind]?.current
                    LabeledContent(profileName(kind)) {
                        Button(t("编辑…", "Edit…")) {
                            editor = .init(subject: .profile(kind, profileWorkspace, current?.revision ?? 0),
                                           text: current?.content ?? "")
                        }
                        if profiles[kind]?.previous != nil {
                            Button(t("恢复上一版", "Restore Previous")) {
                                let owner = profileWorkspace
                                update { try await $0.restoreProfile(kind: kind, workspaceID: owner) }
                            }
                        }
                    }
                }
            } header: {
                Text(t("个性化", "Personalization"))
            } footer: {
                Text(profileWorkspace == nil
                     ? t("这些内容用于普通任务的对话。", "These details are used in ordinary task conversations.")
                     : t("这些内容只应用到所选项目。", "These details apply to the selected project."))
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .disabled(busy || !workspace.isReady)
        .task(id: scope) { await load() }
        .task(id: workspace.isReady) { if workspace.isReady { await load() } }
        .sheet(item: $editor) { draft in
            MacMemoryEditor(draft: draft) { edited, review in
                try await workspace.withMemoryLibrary { library in
                    switch edited.subject {
                    case .entry(.some(let original), _):
                        try await library.edit(original, content: edited.text, pinned: edited.pinned)
                    case .entry(nil, let target):
                        try await library.save(content: edited.text, scope: target, pinned: edited.pinned, forReview: review)
                    case .profile(let kind, let owner, let revision):
                        try await library.saveProfile(kind: kind, workspaceID: owner, content: edited.text,
                                                      expectedRevision: revision)
                    }
                }
                await load()
            }
            #if FLOE_MAC_HOST_SMOKE
            .onAppear { Self.smokeEditorMounted = true }
            .onDisappear { Self.smokeEditorMounted = false }
            #endif
        }
        .confirmationDialog(t("删除这条记忆？", "Delete This Memory?"), isPresented: Binding(
            get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }
        ), titleVisibility: .visible, presenting: deleteEntry) { entry in
            Button(t("删除", "Delete"), role: .destructive) { update { try await $0.forget(id: entry.id) } }
        }
    }

    private func load(append: Bool = false) async {
        guard workspace.isReady else { return }
        let current = UUID()
        request = current
        let selected = scope
        let owner = profileWorkspace
        let next = append ? cursor : nil
        do {
            let state = try await workspace.withMemoryLibrary { library in
                let page = try await library.list(scope: selected, cursor: next)
                let review = try await library.pendingReview()
                let soul = try await library.profile(kind: .soul, workspaceID: owner)
                let profile = try await library.profile(kind: .userProfile, workspaceID: owner)
                return (page, review, soul, profile)
            }
            guard request == current, !Task.isCancelled else { return }
            entries = append ? entries + state.0.entries : state.0.entries
            cursor = state.0.nextCursor
            pending = state.1.candidates.filter { selected == nil || $0.candidate.scope == selected }
            profiles = [.soul: state.2, .userProfile: state.3]
            problem = nil
        } catch {
            guard request == current, !Task.isCancelled else { return }
            problem = t("无法读取记忆。", "Couldn’t read memories.")
        }
    }

    private func resolve(_ id: UUID, keep: Bool) {
        update { try await $0.resolveReview(id: id, keep: keep) }
    }

    private func update(_ action: @escaping @MainActor (FloeMacMemoryLibrary) async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await workspace.withMemoryLibrary(action)
                await load()
            } catch {
                problem = t("无法保存更改。请刷新后重试。", "Couldn’t save changes. Refresh and try again.")
            }
        }
    }

    private func scopeName(_ scope: MemoryScope) -> String {
        switch scope {
        case .userProfile: t("个人", "Personal")
        case .agentGlobal: t("跨任务", "Across Tasks")
        case .workspace(let id): workspace.workspaces.first { $0.id == id }?.name ?? t("项目", "Project")
        case .task(let id): workspace.conversations.first { $0.id == id }?.title ?? t("任务", "Task")
        }
    }

    private func profileName(_ kind: PersonalizationDocumentKind) -> String {
        kind == .soul ? t("回复偏好", "Response Preferences") : t("关于我", "About Me")
    }

    private func t(_ chinese: String, _ english: String) -> String { MacPermissionsText.t(chinese, english) }
}

private struct MacMemoryEditor: View {
    enum Subject {
        case entry(original: MemoryEntry?, scope: MemoryScope)
        case profile(PersonalizationDocumentKind, UUID?, Int)
    }

    struct Draft: Identifiable {
        let id = UUID()
        let subject: Subject
        var text: String
        var pinned = false
    }

    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    @State private var busy = false
    @State private var error = false
    let save: (Draft, Bool) async throws -> Void

    init(draft: Draft, save: @escaping (Draft, Bool) async throws -> Void) {
        _draft = State(initialValue: draft)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("编辑内容", "Edit Content")).font(.headline)
            TextEditor(text: $draft.text).frame(minHeight: 160).font(.body)
                .accessibilityLabel(t("内容", "Content"))
            if case .entry = draft.subject { Toggle(t("置顶", "Pin"), isOn: $draft.pinned) }
            if error {
                Text(t("无法保存。请检查内容长度，移除凭据，或重新打开编辑。",
                       "Couldn’t save. Check the length, remove credentials, or reopen the editor."))
                    .foregroundStyle(.red)
            }
            HStack {
                Button(t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if case .entry(nil, _) = draft.subject, !draft.pinned {
                    Button(t("加入待审", "Add for Review")) { commit(review: true) }
                        .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button(t("保存", "Save")) { commit(review: false) }.keyboardShortcut(.defaultAction)
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 540)
        .disabled(busy)
    }

    private func commit(review: Bool) {
        let edited = draft
        busy = true
        error = false
        Task {
            defer { busy = false }
            do { try await save(edited, review); dismiss() }
            catch { self.error = true }
        }
    }

    private func t(_ chinese: String, _ english: String) -> String { MacPermissionsText.t(chinese, english) }
}
