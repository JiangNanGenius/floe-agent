// FloeApp — Chat-first home screen.
//
// SPDX-License-Identifier: MPL-2.0
//
// Home IS the chat entry: a bottom-pinned composer (always visible,
// keyboard-safe via safeAreaInset) over the recent-thread list. Sending
// creates a conversation and navigates straight into its thread — no
// intermediate workbench. Without a configured model the app stays fully
// usable (threads readable, files/hosts reachable); only AI send is
// gated, with a compact setup entry. Pending approvals surface as a
// badge strip above the composer.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence

/// The Chat-first home: recent threads + bottom composer.
struct ChatHomeView: View {
    @StateObject private var viewModel: ChatHomeViewModel
    @EnvironmentObject private var router: AppRouter

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: ChatHomeViewModel(center: center))
    }

    var body: some View {
        threadList
            .background(FloeTheme.groupedSurface)
            .navigationTitle("tab.home")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerArea
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .overlay {
                if viewModel.isLoading && viewModel.recentConversations.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                }
            }
    }

    // MARK: - Recent threads

    private var threadList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if viewModel.recentConversations.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    ForEach(viewModel.recentConversations) { conversation in
                        threadRow(conversation)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(FloeTheme.primary)
                .accessibilityHidden(true)
            Text("home.empty.title")
                .font(FloeTheme.Typography.section)
            Text("home.empty.subtitle")
                .font(FloeTheme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func threadRow(_ conversation: ConversationRecord) -> some View {
        Button {
            router.openConversation(conversation.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title.isEmpty
                         ? String(localized: "chat.untitled")
                         : conversation.title)
                        .font(FloeTheme.Typography.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(conversation.updatedAt, style: .relative)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let state = viewModel.latestRunStates[conversation.id] {
                    runStatePill(state)
                }
                Image(systemName: "chevron.right")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.title.isEmpty
            ? String(localized: "chat.untitled")
            : conversation.title)
    }

    /// Status pill — copy and color come only from RunStateLocalizer
    /// (§6.2); this view never interprets machine state names.
    private func runStatePill(_ state: String) -> some View {
        Text(RunStateLocalizer.title(for: state))
            .font(FloeTheme.Typography.metadata)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RunStateLocalizer.color(for: state).opacity(0.16),
                in: Capsule()
            )
            .foregroundStyle(RunStateLocalizer.color(for: state))
    }

    // MARK: - Composer area (bottom-pinned)

    private var composerArea: some View {
        VStack(spacing: 0) {
            if !viewModel.pendingApprovals.isEmpty {
                approvalsStrip
            }
            if !viewModel.hasConfiguredProvider {
                providerBar
            }
            if let error = viewModel.actionError {
                errorBar(error)
            }
            ThreadComposerView(
                draft: $viewModel.draft,
                selectedModelID: $viewModel.selectedModelID,
                models: viewModel.availableModels,
                modelName: viewModel.activeModelName,
                providerConfigured: viewModel.hasConfiguredProvider,
                isRunning: false,
                canSend: viewModel.canSend,
                projects: viewModel.availableProjects,
                selectedProjectID: $viewModel.selectedProjectID,
                executionTarget: $viewModel.executionTarget,
                agentMode: $viewModel.agentMode,
                attachments: $viewModel.attachments,
                onSend: sendTask,
                onStop: {}
            )
        }
    }

    /// Compact pending-approvals badge strip: opens the owning thread.
    private var approvalsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingApprovals) { approval in
                    Button {
                        router.openConversation(approval.conversationID, runID: approval.runID)
                    } label: {
                        Label(
                            approval.toolCall.toolName,
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(FloeTheme.pending.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel(
                        String(localized: "approval.required")
                            + " " + approval.toolCall.toolName
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .background(FloeTheme.chromeMaterial)
    }

    /// Model-setup entry shown only when no provider is configured.
    private var providerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("chat.add_provider.hint")
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Button("setup.launcher.open") { router.presentedSetup = .manual }
                .buttonStyle(.bordered)
                .frame(minHeight: FloeTheme.minimumTarget)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.pending.opacity(0.08))
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(FloeTheme.destructive)
                .accessibilityHidden(true)
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.destructive)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.destructive.opacity(0.08))
    }

    // MARK: - Actions

    /// Sends the draft and navigates straight into the new thread.
    private func sendTask() {
        Task {
            if let conversationID = await viewModel.sendNewTask() {
                router.openConversation(conversationID)
            }
        }
    }
}
#endif
