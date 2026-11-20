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
                    Text(FloeL10n.l("app.git_hub_source_card.view_saved_github_source")).font(.caption).foregroundStyle(.secondary)
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
                } else if loading { ProgressView(FloeL10n.l("app.git_hub_source_card.opening_source")) }
                else {
                    ContentUnavailableView {
                        Label(FloeL10n.l("app.git_hub_source_card.source_unavailable"), systemImage: "doc.questionmark")
                    } description: { Text(error ?? FloeL10n.l("app.git_hub_source_card.this_saved_read_is_no")) }
                    actions: { Button(FloeL10n.l("action.retry")) { Task { await load() } } }
                }
            }.navigationTitle(FloeL10n.l("app.git_hub_source_card.github_source"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(FloeL10n.l("help.done")) { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button(FloeL10n.l("app.git_hub_source_card.return_to_task"), systemImage: "arrow.uturn.backward") {
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
                            throw FloeError.validationFailed(FloeL10n.l("app.git_hub_source_card.open_this_issue_in_its"))
                        }
                        let id = try await environment.sourceControlCenter.workOnIssue(url,
                            workspaceID: route.source.workspaceID, originRoot: root)
                        collaboration = nil; dismiss(); router.openConversation(id)
                    }, onReturnTask: { returnToSource?(reference); collaboration = nil; dismiss() },
                    onSignIn: { settingsAfterCollaboration = true; collaboration = nil },
                    authorize: {
                        try route.lease.check()
                        guard route.source.workspaceID != nil else {
                            throw FloeError.validationFailed(FloeL10n.l("app.git_hub_source_card.this_historical_source_is_read"))
                        }
                    })
                    .onDisappear { route.lease.cancel() }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { GitHubSettingsView(center: environment.sourceControlCenter)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(FloeL10n.l("help.done")) { showSettings = false } } } }
            }
            .alert(FloeL10n.l("app.git_hub_source_card.could_not_open_collaboration"), isPresented: Binding(
                get: { resolved != nil && error != nil }, set: { if !$0 { error = nil } })) {
                Button(FloeL10n.l("cad.ui.common.ok"), role: .cancel) { error = nil }
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
        catch { self.error = FloeL10n.l("app.git_hub_source_card.this_saved_read_could_not") }
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
        catch { self.error = FloeL10n.l("app.git_hub_source_card.could_not_open_collaboration_retry") }
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
                throw FloeError.invalidConfiguration(FloeL10n.l("app.git_hub_source_card.choose_an_available_assistant_model"))
            }
            let title = current.snapshot.link.repository.fullName + " #\(current.snapshot.link.number ?? 0)"
            let task = try await conversations.createConversation(title: title)
            // Explicit new-task action: no old project, current UI project,
            // clone, or imported repository is silently adopted.
            let workspace = try await environment.workspaceCenter.ensureReviewConversationWorkspace(
                conversationID: task.id, workspaceID: nil, title: title)
            let goal = FloeL10n.l("app.git_hub_source_card.investigate_and_work_on_this")
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
