// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGit

struct GitHubCollaborationActivity: View {
    @Bindable var center: GitHubCollaborationCenter
    let showDrafts: Bool
    let onSignIn: @MainActor () -> Void
    let onOpenDraft: (UUID) -> Void
    var body: some View {
        List {
            if showDrafts {
                ForEach(center.drafts) { draft in
                    Button { onOpenDraft(draft.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(draft.title.isEmpty ? draft.caption : draft.title, systemImage: "doc.badge.ellipsis")
                                .font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                            Text(draft.caption + (draft.number.map { " · #\($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                            Text(draft.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                    .swipeActions {
                        if canDelete(draft) {
                            Button(ghCollabText("删除草稿", "Delete draft"), role: .destructive) { Task { await center.removeDraft(draft.id) } }
                        }
                    }
                }
                if center.drafts.isEmpty { ContentUnavailableView(ghCollabText("没有草稿", "No drafts"), systemImage: "doc.badge.ellipsis") }
            } else {
                ForEach(center.records) { record in
                    Section {
                        Text(operationTitle(record.request.kind)).font(.headline)
                        Text(record.request.repository.fullName + (record.request.number.map { " #\($0)" } ?? ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                        GitHubCollaborationOperationRow(center: center, record: record, onSignIn: onSignIn)
                        if center.drafts.contains(where: { $0.id == record.id }) {
                            Button(ghCollabText("打开草稿", "Open draft")) { onOpenDraft(record.id) }.frame(minHeight: 44)
                        }
                    }
                }
                if center.records.isEmpty { ContentUnavailableView(ghCollabText("暂无操作记录", "No activity yet"), systemImage: "clock.arrow.circlepath") }
            }
            if let error = center.operationError { GitHubCollaborationNotice(message: error) }
            if let error = center.storageError { GitHubCollaborationNotice(message: error, retry: { Task { await center.bootstrap() } }) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(showDrafts ? ghCollabText("草稿", "Drafts") : ghCollabText("操作记录", "Activity"))
        .task { await center.refreshRecords() }
        .refreshable { await center.refreshRecords() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.activity")
    }
    private func canDelete(_ draft: GitHubCollaborationDraft) -> Bool {
        guard center.activeOperationID != draft.id else { return false }
        if !draft.prepared { return true }
        return center.records.first(where: { $0.id == draft.id }).map { $0.state == .acknowledged || $0.state == .rejected || $0.state == .prepared } ?? false
    }
    private func operationTitle(_ kind: GitHubPreparedMutation.Kind) -> String {
        switch kind {
        case .createIssue: ghCollabText("新建问题", "Create issue")
        case .updateIssue: ghCollabText("更改问题状态", "Change issue state")
        case .reply: ghCollabText("回复", "Reply")
        case .createPull: ghCollabText("新建拉取请求", "Create pull request")
        case .review: ghCollabText("提交评审", "Submit review")
        case .lineComment: ghCollabText("行内评论", "Line comment")
        case .mergePull: ghCollabText("合并拉取请求", "Merge pull request")
        case .rerunActions: ghCollabText("重新运行作业", "Re-run jobs")
        case .rerunFailedActions: ghCollabText("重跑失败作业", "Re-run failed jobs")
        case .cancelActions: ghCollabText("取消运行", "Cancel run")
        }
    }
}

struct GitHubCollaborationOperationRow: View {
    @Bindable var center: GitHubCollaborationCenter
    let record: GitHubMutationRecord
    let onSignIn: @MainActor () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
            if record.state == .unknown || record.state == .sending {
                Text(ghCollabText("响应尚未确认，请核对原操作的结果。", "The response is not confirmed. Check the original action's result."))
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    Task { await center.reconcile(record.id) }
                } label: {
                    if center.reconcilingID == record.id { ProgressView() }
                    else { Label(ghCollabText("核对结果", "Check result"), systemImage: "arrow.clockwise") }
                }.disabled(center.activeOperationID != nil || center.reconcilingID != nil).frame(minHeight: 44)
                .accessibilityIdentifier("github.collaboration.operation.check")
            }
            if let result = record.result {
                Link(ghCollabText("查看 GitHub 结果", "View GitHub result"), destination: result.url).frame(minHeight: 44)
            } else {
                Link(ghCollabText("在 GitHub 查看", "View on GitHub"), destination: record.request.targetURL).frame(minHeight: 44)
            }
            if center.needsSignIn { Button(ghCollabText("连接 GitHub", "Connect GitHub"), action: onSignIn) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.operation.\(record.id.uuidString)")
    }
    private var title: String {
        switch record.state {
        case .prepared: ghCollabText("待发送", "Ready to send")
        case .sending: ghCollabText("正在发送", "Sending")
        case .acknowledged: record.result?.confirmation == .observed ? ghCollabText("已核对当前状态", "Current state verified") : ghCollabText("已发送并核对", "Sent and verified")
        case .rejected: ghCollabText("GitHub 未接受此次更改", "GitHub did not accept this change")
        case .unknown: ghCollabText("等待核对结果", "Result needs checking")
        }
    }
    private var symbol: String {
        switch record.state {
        case .prepared: "paperplane"
        case .sending: "arrow.trianglehead.2.clockwise.rotate.90"
        case .acknowledged: "checkmark.circle"
        case .rejected: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}
#endif
