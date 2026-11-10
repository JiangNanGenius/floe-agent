// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGit

struct GitHubCollaborationComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var center: GitHubCollaborationCenter
    let draftID: UUID
    let onSignIn: @MainActor () -> Void
    @State private var editingRepository = false
    @State private var repositoryInput = ""
    private var draft: GitHubCollaborationDraft? { center.drafts.first { $0.id == draftID } }
    private var record: GitHubMutationRecord? { center.records.first { $0.id == draftID } }
    var body: some View {
        NavigationStack {
            if let draft {
                Form {
                    Section {
                        Label(draft.scope.repository.fullName + (draft.number.map { " #\($0)" } ?? ""), systemImage: "shippingbox")
                        if let sha = draft.headSHA {
                            Text(ghCollabText("本次更改针对提交 ", "This change targets commit ") + String(sha.prefix(8)))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    inputSections(draft).disabled(draft.prepared || center.activeOperationID == draftID)
                    if let record {
                        Section(ghCollabText("发送状态", "Delivery")) {
                            GitHubCollaborationOperationRow(center: center, record: record, onSignIn: onSignIn)
                        }
                        if record.state == .prepared || record.state == .rejected {
                            Section {
                                Button(ghCollabText("另存为新草稿并修改", "Edit a new draft")) { Task { await center.copyDraftForEditing(draftID) } }
                                    .disabled(center.activeOperationID != nil)
                            } footer: { Text(ghCollabText("保留原发送记录，修改内容会使用新的草稿。", "The original delivery record is retained; edits use a new draft.")) }
                        }
                    }
                    if let error = center.operationError { Section { GitHubCollaborationNotice(message: error) } }
                    if let error = center.storageError { Section { GitHubCollaborationNotice(message: error, retry: { Task { await center.flushDraft(draftID) } }) } }
                    if center.needsSignIn { Section { Button(ghCollabText("连接 GitHub", "Connect GitHub"), action: onSignIn) } }
                    if center.activeOperationID == draftID { Section { ProgressView(ghCollabText("正在确认并发送", "Checking and sending")) } }
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(draft.caption).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ghCollabText("完成", "Done")) {
                            Task { await center.flushDraft(draftID); if center.storageError == nil { dismiss() } }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(draft.kind == .mergePull ? ghCollabText("合并", "Merge") : ghCollabText("发送", "Send")) { center.sendDraft(draftID) }
                            .disabled(!ready(draft) || center.activeOperationID != nil || center.reconcilingID != nil)
                            .accessibilityIdentifier("github.collaboration.draft.send")
                    }
                }
                .interactiveDismissDisabled(center.storageError != nil)
                .alert(ghCollabText("来源仓库", "Head repository"), isPresented: $editingRepository) {
                    TextField("owner/repository", text: $repositoryInput).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(ghCollabText("使用仓库", "Use repository")) { Task { await center.changeHeadRepository(repositoryInput, draftID: draftID) } }
                    Button(ghCollabText("取消", "Cancel"), role: .cancel) {}
                } message: { Text(ghCollabText("输入 GitHub 仓库地址或 owner/repository。", "Enter a GitHub repository URL or owner/repository.")) }
                .onDisappear { Task { await center.flushDraft(draftID) } }
            } else {
                ContentUnavailableView(ghCollabText("找不到这份草稿", "Draft unavailable"), systemImage: "doc.badge.ellipsis")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ghCollabText("完成", "Done")) { dismiss() } } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.composer")
    }
    @ViewBuilder private func inputSections(_ draft: GitHubCollaborationDraft) -> some View {
        switch draft.kind {
        case .createIssue, .createPull:
            Section(ghCollabText("标题", "Title")) {
                TextField(ghCollabText("概括这次更改或问题", "Summarize the change or issue"), text: binding(\.title, fallback: draft.title), axis: .vertical)
                    .lineLimit(1...3).accessibilityIdentifier("github.collaboration.draft.title")
            }
            if draft.kind == .createPull { branchSection(draft) }
            descriptionSection(draft)
        case .reply: descriptionSection(draft)
        case .review:
            Section(ghCollabText("评审结论", "Review")) {
                Picker(ghCollabText("结论", "Decision"), selection: binding(\.reviewEvent, fallback: draft.reviewEvent)) {
                    Text(ghCollabText("评论", "Comment")).tag(GitHubReviewEvent.comment)
                    Text(ghCollabText("批准", "Approve")).tag(GitHubReviewEvent.approve)
                    Text(ghCollabText("要求修改", "Request changes")).tag(GitHubReviewEvent.requestChanges)
                }
            }
            descriptionSection(draft)
            headRefresh(draft)
        case .lineComment:
            if let line = draft.reviewLine {
                Section(ghCollabText("代码位置", "Code location")) {
                    Text(line.path).font(.subheadline.monospaced()).textSelection(.enabled)
                    Text(ghCollabText("第 \(line.line) 行", "Line \(line.line)") + " · " +
                        (line.side == .left ? ghCollabText("原版本", "Original") : ghCollabText("新版本", "Changed")))
                }
            }
            descriptionSection(draft)
        case .mergePull:
            Section {
                Picker(ghCollabText("方式", "Method"), selection: binding(\.mergeMethod, fallback: draft.mergeMethod)) {
                    Text(ghCollabText("压缩合并", "Squash and merge")).tag(GitHubMergeMethod.squash)
                    Text(ghCollabText("创建合并提交", "Create a merge commit")).tag(GitHubMergeMethod.merge)
                    Text(ghCollabText("变基合并", "Rebase and merge")).tag(GitHubMergeMethod.rebase)
                }
            } header: { Text(ghCollabText("合并方式", "Merge method")) }
            footer: { Text(ghCollabText("GitHub 会检查当前提交及仓库合并规则。", "GitHub checks the current commit and repository merge rules.")) }
            headRefresh(draft)
        case .updateIssue:
            Section { Label(draft.closeIssue ? ghCollabText("关闭这个问题", "Close this issue") : ghCollabText("重新打开这个问题", "Reopen this issue"), systemImage: draft.closeIssue ? "checkmark.circle" : "arrow.counterclockwise.circle") }
        case .rerunActions, .rerunFailedActions, .cancelActions:
            if let run = draft.actionRun {
                Section {
                    LabeledContent(ghCollabText("运行", "Run"), value: "#\(run.id)")
                    LabeledContent(ghCollabText("尝试次数", "Attempt"), value: String(run.runAttempt))
                    Text(draft.caption).font(.headline)
                } header: { Text(ghCollabText("本次运行", "Selected run")) }
                footer: { Text(ghCollabText("仅操作选中的 GitHub 运行。", "This only acts on the selected GitHub run.")) }
            }
        }
    }
    private func descriptionSection(_ draft: GitHubCollaborationDraft) -> some View {
        Section {
            TextEditor(text: binding(\.body, fallback: draft.body)).frame(minHeight: 180)
                .accessibilityIdentifier("github.collaboration.draft.body")
        } header: { Text(ghCollabText("内容", "Description")) }
        footer: {
            if draft.body.utf8.count > 65_000 { Text(ghCollabText("内容过长，请缩短后保存。", "This text is too long. Shorten it before saving.")) }
            else { Text(ghCollabText("支持 Markdown，草稿会保存在此项目中。", "Markdown is supported. Drafts are saved for this project.")) }
        }
    }
    private func branchSection(_ draft: GitHubCollaborationDraft) -> some View {
        Section(ghCollabText("比较分支", "Compare branches")) {
            LabeledContent(ghCollabText("目标仓库", "Base repository"), value: draft.scope.repository.fullName)
            Picker(ghCollabText("合并到", "Base branch"), selection: binding(\.base, fallback: draft.base)) {
                Text(ghCollabText("选择分支", "Select a branch")).tag("")
                ForEach(center.baseBranches) { Text($0.name).tag($0.name) }
            }.pickerStyle(.navigationLink)
            if center.baseNextPage != nil { Button(ghCollabText("更多目标分支", "More base branches")) { Task { await center.loadBranches(for: draftID, moreBase: true) } } }
            Button {
                repositoryInput = (draft.headRepository ?? draft.scope.repository).fullName; editingRepository = true
            } label: { LabeledContent(ghCollabText("来源仓库", "Head repository"), value: (draft.headRepository ?? draft.scope.repository).fullName) }
            Picker(ghCollabText("比较", "Compare branch"), selection: Binding(get: { draft.head }, set: { center.selectHead($0, draftID: draftID) })) {
                Text(ghCollabText("选择分支", "Select a branch")).tag("")
                ForEach(center.headBranches) { Text($0.name).tag($0.name) }
            }.pickerStyle(.navigationLink)
            if center.headNextPage != nil { Button(ghCollabText("更多来源分支", "More head branches")) { Task { await center.loadBranches(for: draftID, moreHead: true) } } }
            if center.branchesLoading { ProgressView(ghCollabText("正在读取分支", "Loading branches")) }
            Button(ghCollabText("刷新分支", "Refresh branches")) { Task { await center.loadBranches(for: draftID) } }.disabled(center.branchesLoading)
            Toggle(ghCollabText("创建为草稿", "Create as draft"), isOn: binding(\.draftPull, fallback: draft.draftPull))
        }
    }
    private func headRefresh(_ draft: GitHubCollaborationDraft) -> some View {
        Section {
            Button(ghCollabText("更新到最新提交", "Use latest commit")) { Task { await center.refreshDraftHead(draftID) } }
        }
    }
    private func binding<Value>(_ path: WritableKeyPath<GitHubCollaborationDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { center.drafts.first(where: { $0.id == draftID })?[keyPath: path] ?? fallback },
                set: { value in center.updateDraft(draftID) { $0[keyPath: path] = value } })
    }
    private func ready(_ draft: GitHubCollaborationDraft) -> Bool {
        guard center.canWrite, (try? draft.validate()) != nil else { return false }
        if let record, record.state != .prepared { return false }
        if draft.prepared && record == nil { return false }
        let title = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let body = !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch draft.kind {
        case .createIssue: return title
        case .createPull: return title && !draft.base.isEmpty && !draft.head.isEmpty && draft.headSHA != nil &&
            ((draft.headRepository ?? draft.scope.repository) != draft.scope.repository || draft.head != draft.base)
        case .reply, .lineComment: return body
        case .review: return draft.headSHA != nil && (draft.reviewEvent == .approve || body)
        case .mergePull: return draft.headSHA != nil
        case .updateIssue: return draft.number != nil
        case .rerunActions, .rerunFailedActions, .cancelActions: return draft.actionRun != nil
        }
    }
}
#endif
