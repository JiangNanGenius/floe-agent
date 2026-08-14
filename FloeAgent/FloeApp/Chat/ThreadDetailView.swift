// FloeApp — Canonical foldable thread detail.
//
// SPDX-License-Identifier: MPL-2.0
//
// One conversation's execution thread: persisted run events in sequence
// order, a live snapshot while the selected run is non-terminal, pending
// approval cards, and a composer (glass) for the next run. Every state —
// loading, streaming, waiting-approval, failed, terminal — is explicit;
// nothing invents live data.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence
import FloeSecurity

/// The canonical thread: messages + run events for one conversation.
struct ThreadDetailView: View {
    @StateObject private var viewModel: ThreadDetailViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(conversationID: UUID, center: ConversationCenter) {
        _viewModel = StateObject(
            wrappedValue: ThreadDetailViewModel(conversationID: conversationID, center: center)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.runs.isEmpty {
                runPicker
            }
            Divider()
            threadScroll
            if let error = viewModel.actionError {
                errorBanner(error)
            }
            composer
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("thread.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { stateToolbar }
        .task {
            viewModel.selectedRunID = router.selectedRunID
            await viewModel.load()
        }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Run picker (multiple runs per conversation)

    private var runPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.runs) { run in
                    Button {
                        Task { await viewModel.selectRun(run.id) }
                    } label: {
                        Text(run.startedAt, style: .time)
                            .font(FloeTheme.Typography.metadata)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                run.id == viewModel.selectedRun?.id
                                    ? FloeTheme.primary.opacity(0.16)
                                    : FloeTheme.groupedSurface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel(
                        String(localized: "thread.run_at") + " "
                            + run.startedAt.formatted(date: .omitted, time: .shortened)
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Thread content

    private var threadScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // The user's goal, from the persisted messages.
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    // The canonical event thread of the selected run.
                    ForEach(viewModel.events) { event in
                        ThreadEventView(
                            event: event,
                            isLive: viewModel.isRunning,
                            hasError: viewModel.events.contains { $0.kind == .error },
                            onRetry: viewModel.selectedRun?.state == "failed"
                                ? { Task { await viewModel.retry() } }
                                : nil
                        )
                            .id(event.id)
                    }

                    // Live streaming tail, only while the run is active.
                    if viewModel.isRunning && !viewModel.liveReasoningText.isEmpty {
                        ReasoningBlockView(
                            text: viewModel.liveReasoningText,
                            isStreaming: true
                        )
                        .id("live-reasoning")
                    }

                    if viewModel.isRunning && !viewModel.liveStreamedText.isEmpty {
                        AssistantMessageView(
                            text: viewModel.liveStreamedText,
                            isStreaming: true
                        )
                        .id("live-tail")
                    }

                    if viewModel.isRunning
                        && viewModel.liveStreamedText.isEmpty
                        && viewModel.liveReasoningText.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(LocalizedStringKey(viewModel.hasProviderActivity
                                ? "thread.model_thinking"
                                : "thread.contacting_provider"))
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    // Pending approvals for this run.
                    ForEach(viewModel.pendingApprovals) { approval in
                        ApprovalCardView(approval: approval) { decision in
                            Task { await viewModel.resolve(approval, decision: decision) }
                        }
                        .id(approval.id)
                    }

                    if viewModel.events.isEmpty && viewModel.messages.isEmpty {
                        ContentUnavailableView {
                            Label("thread.empty", systemImage: "text.bubble")
                        } description: {
                            Text("thread.empty.hint")
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.events.count) { _, _ in
                guard let last = viewModel.events.last else { return }
                withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - State toolbar (status + Stop/Retry + inspector)

    @ToolbarContentBuilder
    private var stateToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if router.inspectorVisible {
                    router.hideInspector()
                } else {
                    router.showInspector(.workspaceFiles)
                }
            } label: {
                Label("inspector.files", systemImage: "sidebar.right")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("inspector.files")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.isRunning {
                Button(role: .destructive) {
                    Task { await viewModel.cancel() }
                } label: {
                    Label("action.stop", systemImage: "stop.circle")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("action.stop")
            } else if let run = viewModel.selectedRun, run.state == "failed" {
                Button {
                    Task { await viewModel.retry() }
                } label: {
                    Label("action.retry", systemImage: "arrow.clockwise")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("action.retry")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let state = viewModel.liveStateName {
                Text(RunStateLocalizer.title(for: state))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(RunStateLocalizer.color(for: state))
                    .accessibilityLabel(
                        String(localized: "thread.state") + " "
                            + String(localized: RunStateLocalizer.title(for: state))
                    )
            }
        }
    }

    // MARK: - Error banner (honest failure surface)

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(FloeTheme.destructive)
                .accessibilityHidden(true)
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.destructive)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(FloeTheme.destructive.opacity(0.08))
    }

    // MARK: - Composer (glass; reading surfaces stay opaque)

    private var composer: some View {
        VStack(spacing: 0) {
            if viewModel.needsProvider {
                addProviderBar
            }
            ThreadComposerView(
                draft: $viewModel.draft,
                selectedModelID: $viewModel.selectedModelID,
                models: viewModel.availableModels,
                modelName: viewModel.selectedModelName,
                providerConfigured: !viewModel.needsProvider,
                isRunning: viewModel.isRunning,
                canSend: viewModel.canSend || viewModel.isRunning,
                projects: viewModel.availableProjects,
                selectedProjectID: $viewModel.selectedProjectID,
                executionTarget: $viewModel.executionTarget,
                agentMode: $viewModel.agentMode,
                attachments: $viewModel.attachments,
                onSend: { Task { await viewModel.send() } },
                onStop: { Task { await viewModel.cancel() } }
            )
        }
    }

    private var addProviderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("chat.add_provider.hint")
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Button("setup.launcher.open") { router.presentedSetup = .manual }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(FloeTheme.pending.opacity(0.08))
    }
}

/// A persisted message: user goals render as right-aligned bubbles with
/// attachment chips; other roles (final assistant answers) render as
/// Markdown in the left-aligned reading column.
private struct MessageBubble: View {
    let message: PersistedMessage

    private var attachmentNames: [String] {
        message.parts
            .filter { $0.kind == .file || $0.kind == .image }
            .map { $0.metadata["name"] ?? $0.text ?? "" }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        if message.role == "user" {
            UserMessageBubble(text: message.content, attachments: attachmentNames)
        } else {
            AssistantMessageView(text: message.content, isStreaming: false)
        }
    }
}
#endif
