// FloeApp — Home overview column (iPad second column).
//
// SPDX-License-Identifier: MPL-2.0
//
// Home's middle column is a task overview, NOT the conversation-history
// list (that is Chat's content column). It shows at most three quiet
// sections — active tasks, pending approvals, recent threads — and stays
// empty-clean when there is nothing to show. Rows open the owning thread
// in Home's detail column via the router.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence

/// The iPad Home content column: task overview for the launchpad.
struct HomeOverviewView: View {
    @ObservedObject private var center: ConversationCenter
    @StateObject private var viewModel: HomeLaunchpadViewModel
    @EnvironmentObject private var router: AppRouter

    init(center: ConversationCenter) {
        self.center = center
        _viewModel = StateObject(wrappedValue: HomeLaunchpadViewModel(center: center))
    }

    var body: some View {
        List {
            if !viewModel.activeTasks.isEmpty {
                Section("home.active_tasks") {
                    ForEach(viewModel.activeTasks) { conversation in
                        overviewRow(conversation, showsState: true)
                    }
                }
            }
            if !viewModel.pendingApprovals.isEmpty {
                Section("home.pending_approvals") {
                    ForEach(viewModel.pendingApprovals) { approval in
                        Button {
                            router.openThreadFromHome(approval.conversationID, runID: approval.runID)
                        } label: {
                            Label(approval.toolCall.toolName,
                                  systemImage: "exclamationmark.shield")
                                .foregroundStyle(FloeTheme.pending)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .accessibilityLabel(
                            String(localized: "approval.required")
                                + " " + approval.toolCall.toolName
                        )
                    }
                }
            }
            if !viewModel.recentConversations.isEmpty {
                Section("home.recent") {
                    ForEach(Array(viewModel.recentConversations.prefix(8))) { conversation in
                        overviewRow(conversation, showsState: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if overviewIsEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("tab.home", systemImage: "house")
                } description: {
                    Text("home.overview.empty")
                }
            }
        }
        .navigationTitle("tab.home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.navigate(to: .chat)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("tab.chat")
                .accessibilityIdentifier("home.overview.open_chat")
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private var overviewIsEmpty: Bool {
        viewModel.activeTasks.isEmpty
            && viewModel.pendingApprovals.isEmpty
            && viewModel.recentConversations.isEmpty
    }

    private func overviewRow(_ conversation: ConversationRecord, showsState: Bool) -> some View {
        Button {
            router.openThreadFromHome(conversation.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title.isEmpty
                         ? String(localized: "chat.untitled")
                         : conversation.title)
                        .font(FloeTheme.Typography.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(
                        conversation.updatedAt,
                        format: .dateTime.month(.abbreviated).day().hour().minute()
                    )
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if showsState, let state = viewModel.latestRunStates[conversation.id] {
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
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(conversation.title.isEmpty
            ? String(localized: "chat.untitled")
            : conversation.title)
    }
}
#endif
