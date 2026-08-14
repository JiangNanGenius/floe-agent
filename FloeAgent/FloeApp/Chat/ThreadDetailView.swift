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
                        ThreadEventView(event: event)
                            .id(event.id)
                    }

                    // Live streaming tail, only while the run is active.
                    if viewModel.isRunning && !viewModel.liveReasoningText.isEmpty {
                        LiveReasoningDisclosure(text: viewModel.liveReasoningText)
                            .id("live-reasoning")
                    }

                    if viewModel.isRunning && !viewModel.liveStreamedText.isEmpty {
                        Text(viewModel.liveStreamedText)
                            .font(FloeTheme.Typography.body)
                            .textSelection(.enabled)
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

    // MARK: - State toolbar (status + Stop/Retry)

    @ToolbarContentBuilder
    private var stateToolbar: some ToolbarContent {
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
                Text(localizedState(state))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "thread.state") + " " + state)
            }
        }
    }

    private func localizedState(_ state: String) -> LocalizedStringKey {
        switch state {
        case "preparing": "thread.state.preparing"
        case "streamingModel": "thread.state.streaming"
        case "executingTool": "thread.state.executing_tool"
        case "waitingApproval": "thread.state.waiting_approval"
        case "completed": "thread.state.completed"
        case "failed": "thread.state.failed"
        case "checkpointed": "thread.state.checkpointed"
        case "cancelling": "thread.state.cancelling"
        default: LocalizedStringKey(state)
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
            } else if let modelName = viewModel.selectedModelName {
                HStack {
                    Menu {
                        ForEach(viewModel.availableModels) { model in
                            Button {
                                viewModel.selectedModelID = model.id
                            } label: {
                                if viewModel.selectedModelID == model.id {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(modelName, systemImage: "chevron.down")
                            .font(FloeTheme.Typography.metadata)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .background(FloeTheme.chromeMaterial)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $viewModel.draft, axis: .vertical) {
                    Text("home.new_task.placeholder")
                }
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .disabled(viewModel.needsProvider)
                .accessibilityLabel("home.new_task.placeholder")

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(FloeTheme.primary)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("thread.send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FloeTheme.chromeMaterial)
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

/// A live reasoning block follows the familiar agent-app pattern: compact by
/// default, clearly separate from the answer, and expandable without changing
/// the canonical assistant message.
private struct LiveReasoningDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("thread.model_thinking")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                if !isExpanded {
                    Text(preview)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var preview: String {
        text.split(whereSeparator: { $0.isNewline })
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// A persisted user/assistant message bubble.
private struct MessageBubble: View {
    let message: PersistedMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 24) }
            Text(message.content)
                .font(FloeTheme.Typography.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == "user"
                        ? FloeTheme.primary.opacity(0.14)
                        : FloeTheme.groupedSurface,
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.role != "user" { Spacer(minLength: 24) }
        }
    }
}
#endif
