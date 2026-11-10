// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGit
import FloePersistence
import FloeAgentRuntime

private struct GitHubSourceReturnKey: EnvironmentKey { static let defaultValue: GitHubSourceReturnAction? = nil }
extension EnvironmentValues {
    var gitHubSourceReturn: GitHubSourceReturnAction? {
        get { self[GitHubSourceReturnKey.self] }
        set { self[GitHubSourceReturnKey.self] = newValue }
    }
}

struct GitHubSourceCard: View {
    let reference: GitHubSourceReference
    let inputSummary: String?
    @State private var presented = false
    @Environment(\.chatInlineContentScope) private var host
    private var title: String {
        guard let inputSummary, inputSummary.utf8.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: Data(inputSummary.utf8)) as? [String: Any],
              let url = object["url"] as? String, let link = try? GitHubLinkParser.parse(url) else { return "GitHub" }
        return link.repository.fullName + (link.number.map { " #\($0)" } ?? "")
    }
    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.title3).foregroundStyle(.tint)
                    .frame(width: 34, height: 34).background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(sourceText("查看已读取的 GitHub 内容", "View saved GitHub source")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .disabled(host?.isTemporary != false || host?.conversationID != reference.conversationID)
            .accessibilityIdentifier("github.source.open")
            .sheet(isPresented: $presented) { GitHubSourceSheet(reference: reference) }
    }
}

private struct GitHubSourceSheet: View {
    let reference: GitHubSourceReference
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gitHubSourceReturn) private var returnToSource
    @State private var resolved: ResolvedGitHubSource?
    @State private var error: String?
    @State private var loading = false
    @State private var acting = false
    @State private var actionTask: Task<Void, Never>?
    @State private var collaboration: CollaborationRoute?
    @State private var showSettings = false
    @State private var settingsAfterCollaboration = false
    private struct CollaborationRoute: Identifiable {
        let id = UUID()
        let source: ResolvedGitHubSource
        let service: GitHubCollaborationService
        let client: GitHubCollaborationClient
        let lease: SourceControlOperationLease
    }
    var body: some View {
        NavigationStack {
            Group {
                if let resolved {
                    GitHubSourceDetails(snapshot: resolved.snapshot, isBusy: acting, openCollaboration: resolved.opensCollaboration ? {
                        actionTask = Task { await openCollaboration() }
                    } : nil, workInNewTask: resolved.opensCollaboration ? { actionTask = Task { await workInNewTask() } } : nil)
                } else if loading { ProgressView(sourceText("正在打开来源…", "Opening source…")) }
                else {
                    ContentUnavailableView {
                        Label(sourceText("无法打开此来源", "Source unavailable"), systemImage: "doc.questionmark")
                    } description: { Text(error ?? sourceText("此读取结果已不在本机，请让助手重新读取。", "This saved read is no longer retained. Ask the assistant to read it again.")) }
                    actions: { Button(sourceText("重试", "Retry")) { Task { await load() } } }
                }
            }.navigationTitle(sourceText("GitHub 来源", "GitHub source"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(sourceText("完成", "Done")) { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button(sourceText("返回原任务", "Return to task"), systemImage: "arrow.uturn.backward") {
                            returnToSource?(reference); dismiss()
                        }.accessibilityIdentifier("github.source.returnTask")
                    }
                }
        }.task(id: reference) { await load() }
            .sheet(item: $collaboration, onDismiss: {
                collaboration?.lease.cancel(); collaboration = nil
                if settingsAfterCollaboration { settingsAfterCollaboration = false; showSettings = true }
            }) { route in
                GitHubCollaborationView(repository: route.source.snapshot.link.repository,
                    workspaceID: route.source.workspaceID, sourceTaskID: reference.conversationID,
                    service: route.service, client: route.client,
                    tokenProvider: { try GitHubCredentialStore().token() ?? "" }, initialLink: route.source.snapshot.link,
                    onWorkOnIssue: { url in
                        try route.lease.check()
                        guard let root = route.lease.workspaceRoot, route.source.workspaceID != nil else {
                            throw FloeError.validationFailed(sourceText("请先在原项目中打开此问题。", "Open this issue in its original project first."))
                        }
                        let id = try await environment.sourceControlCenter.workOnIssue(url,
                            workspaceID: route.source.workspaceID, originRoot: root)
                        collaboration = nil; dismiss(); router.openConversation(id)
                    }, onReturnTask: { returnToSource?(reference); collaboration = nil; dismiss() },
                    onSignIn: { settingsAfterCollaboration = true; collaboration = nil },
                    authorize: {
                        try route.lease.check()
                        guard route.source.workspaceID != nil else {
                            throw FloeError.validationFailed(sourceText("此历史来源仅供阅读。请从已关联的原项目打开协作。", "This historical source is read-only. Open collaboration from its linked original project."))
                        }
                    })
                    .onDisappear { route.lease.cancel() }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { GitHubSettingsView(center: environment.sourceControlCenter)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(sourceText("完成", "Done")) { showSettings = false } } } }
            }
            .alert(sourceText("无法打开协作", "Could not open collaboration"), isPresented: Binding(
                get: { resolved != nil && error != nil }, set: { if !$0 { error = nil } })) {
                Button(sourceText("好", "OK"), role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onDisappear { actionTask?.cancel(); collaboration?.lease.cancel() }
    }
    private func source() async throws -> ResolvedGitHubSource {
        try await GitHubSourceResolver.resolve(reference, conversations: environment.conversationStore,
            runs: environment.runStore, workspaces: SQLiteWorkspaceStore(database: environment.database),
            captures: ToolResultCaptureStore.shared(durableRoot: ConversationCenter.toolResultCaptureRoot()))
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { let current = try await source(); try Task.checkCancellation(); resolved = current }
        catch is CancellationError { }
        catch { self.error = sourceText("此读取结果无法恢复。请让助手重新读取，原任务仍然保留。", "This saved read could not be restored. Ask the assistant to read it again; the original task is preserved.") }
    }
    private func openCollaboration() async {
        guard !acting else { return }; acting = true
        defer { acting = false }
        do {
            let current = try await source() // recheck deletion/ownership before entering a live feature
            guard current.opensCollaboration else { throw GitHubSourceResolutionError.invalidSource }
            let root: URL?
            if let workspaceID = current.workspaceID,
               let record = try await SQLiteWorkspaceStore(database: environment.database).workspace(id: workspaceID) {
                let lease = try await environment.workspaceCenter.acquireMemorySourceRoot(record)
                root = lease.root
                await lease.release()
            } else { root = nil }
            try Task.checkCancellation()
            collaboration = .init(source: current, service: try environment.gitHubCollaborationService(),
                client: environment.sourceControlCenter.github.collaborationClient(),
                lease: .init(workspaceRoot: root, repositoryRoot: nil, workspaceID: current.workspaceID))
        } catch is CancellationError { }
        catch { self.error = sourceText("无法打开协作。请重试或检查 GitHub 连接。", "Could not open collaboration. Retry or check the GitHub connection.") }
    }
    private func workInNewTask() async {
        guard !acting else { return }; acting = true
        defer { acting = false }
        do {
            let current = try await source()
            try Task.checkCancellation()
            guard current.opensCollaboration else { throw GitHubSourceResolutionError.invalidSource }
            let conversations = environment.conversationCenter
            guard let (provider, model) = conversations.providerAndModel(modelID: nil) else {
                throw FloeError.invalidConfiguration(sourceText("请先选择一个可用的助手模型。", "Choose an available assistant model first."))
            }
            let title = current.snapshot.link.repository.fullName + " #\(current.snapshot.link.number ?? 0)"
            let task = try await conversations.createConversation(title: title)
            // Explicit new-task action: no old project, current UI project,
            // clone, or imported repository is silently adopted.
            let workspace = try await environment.workspaceCenter.ensureReviewConversationWorkspace(
                conversationID: task.id, workspaceID: nil, title: title)
            let goal = sourceText("请研究并处理这个 GitHub 问题或拉取请求：", "Investigate and work on this GitHub issue or pull request: ")
                + current.snapshot.source.resolvedURL.absoluteString
            _ = try await conversations.startRun(goal: goal, in: task.id, provider: provider, model: model,
                workspaceID: workspace, startOrigin: .explicitUserAction)
            dismiss(); router.openConversation(task.id)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private func sourceText(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
#endif
