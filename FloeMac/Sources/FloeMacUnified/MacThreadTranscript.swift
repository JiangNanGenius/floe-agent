// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloePersistence
import SwiftUI

/// Connects the shared iPad transcript to the native Mac workspace and its
/// attachment picker, permissions, and composer draft.
struct MacThreadTranscript: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let conversationID: UUID?
    let searchText: String
    let searchIsActive: Bool
    let focusedMessageID: UUID?
    let requestedMessageID: UUID?
    let openModelSettings: (() -> Void)?
    let openAttachment: (PersistedMessage, AttachmentChipItem) -> Void
    let hasDraft: Bool
    let reuseMessage: (String) -> Void
    let retryPlan: (PlanConfirmationSnapshot) -> (() -> Void)?
    let handleSearchResult: ((UUID, UUID) -> Void)?

    @State private var jump: ThreadTranscriptJump?
    @State private var unavailableResult = false
    @State private var projection = ProjectionCache()

    private var query: ConversationSearchQuery { .init(raw: searchIsActive ? searchText : "") }

    var body: some View {
        let snapshot = projection.read(workspace)
        let items = snapshot.items
        let liveRun = workspace.transcriptRuns.first { $0.id == workspace.transcriptLiveRunID }
        ThreadTranscriptViewport(
            ready: !workspace.isLoadingHistory, searchIsActive: searchIsActive, jump: jump,
            updates: ThreadTranscriptUpdates(textBytes: workspace.streamedText.utf8.count,
                reasoningBytes: workspace.liveReasoning.utf8.count,
                eventCount: workspace.transcriptEventsByRun.values.reduce(0) { $0 + $1.count },
                messageCount: workspace.messages.count, isRunning: workspace.isSending),
            firstRowID: items.first?.id, hasEarlierMessages: workspace.hasEarlierMessages,
            loadingEarlierMessages: workspace.isLoadingEarlierMessages || workspace.isTerminating,
            maximumLineWidth: 824, loadEarlier: {
                let first = workspace.messages.first?.id
                await workspace.loadEarlierMessages()
                return workspace.selectedID == conversationID && workspace.messages.first?.id != first
            }
        ) { layout in
            if items.isEmpty && workspace.pendingPrompt == nil && !workspace.isSending {
                welcome(height: layout.viewportFrame.height)
            } else {
                ThreadTimelineRows(items: items, rowIDs: snapshot.rowIDs, isRunning: workspace.isSending) { item in
                    row(item, layout: layout, decisions: snapshot.decisions, liveRun: liveRun)
                }
                if let prompt = workspace.pendingPrompt { UserMessageBubble(text: prompt) }
                if workspace.isSending && liveRun == nil {
                    if !workspace.liveReasoning.isEmpty { ReasoningBlockView(text: workspace.liveReasoning, isStreaming: true) }
                    if !workspace.streamedText.isEmpty { AssistantMessageView(text: workspace.streamedText, isStreaming: true, allowsReadAloud: false) }
                    else if workspace.pendingApproval == nil { ModelResponseWaitingView() }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if let approval = workspace.pendingApproval {
                MacWorkspaceApprovalView(workspace: workspace, approval: approval)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .background(FloeTheme.readingSurface)
            }
        }
        .task(id: workspace.isLoadingHistory ? nil : requestedMessageID) {
            guard !workspace.isLoadingHistory, let requestedMessageID, let conversationID else { return }
            unavailableResult = false
            let visible = await workspace.revealMessage(requestedMessageID, in: conversationID)
            guard !Task.isCancelled, workspace.selectedID == conversationID else { return }
            if visible && moveToMessage(requestedMessageID) {
                handleSearchResult?(conversationID, requestedMessageID)
            } else {
                unavailableResult = true
            }
        }
        .onChange(of: focusedMessageID) { _, id in
            guard let id else { return }
            unavailableResult = false
            _ = moveToMessage(id)
        }
        .overlay(alignment: .top) {
            if unavailableResult, let requestedMessageID, let conversationID {
                HStack {
                    Text("mac.workspace.searchResultUnavailable")
                    Button {
                        unavailableResult = false
                        handleSearchResult?(conversationID, requestedMessageID)
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel(Text("mac.workspace.dismissSearchNotice"))
                }
                .font(.caption).padding(6).background(.regularMaterial, in: Capsule())
            }
        }
    }

    private func moveToMessage(_ id: UUID) -> Bool {
        guard let rowID = ThreadTimelineMessageLocation.rowID(for: id, items: projection.read(workspace).items,
            messages: workspace.messages, eventsByRun: workspace.transcriptEventsByRun) else { return false }
        jump = ThreadTranscriptJump(rowID: rowID)
        #if FLOE_MAC_HOST_SMOKE
        HostAgentWorkspaceView.smokeLocatedMessageID = id
        #endif
        return true
    }

    private func welcome(height: CGFloat) -> some View {
        VStack(spacing: 12) {
            FloeWorkbenchWelcomeHeader(icon: Image(nsImage: NSImage(named: "FloeBrand") ?? NSApp.applicationIconImage)) {
                Text(workspace.composerMode.prompt)
            }
            if workspace.composerProvider == nil, let openModelSettings {
                Button("host.chat.provider", action: openModelSettings).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(0, height - 34))
    }

    @ViewBuilder private func row(_ item: ThreadTimelineItem, layout: ThreadTranscriptLayout,
                                 decisions: [ToolDecisionAnnotation], liveRun: RunRecord?) -> some View {
        switch item {
        case .earlierEvents(let runID):
            ThreadEarlierActivityRow(runID: runID, viewportFrame: layout.viewportFrame,
                scrollDemand: layout.earlierActivityDemand,
                hasMore: workspace.earlierEventRunIDs.contains(runID),
                loading: workspace.loadingEventRunIDs.contains(runID),
                failed: workspace.failedEarlierEventRunIDs.contains(runID),
                loadEarlier: { id in await workspace.loadEarlierEvents(runID: id) })
        case .userMessage(let message):
            userMessage(message)
        case .assistantMessage(let text, let suffix, _):
            let visible = query.isEmpty ? "" : ConversationSearchText.visibleText(markdown: text)
            let ranges = query.ranges(in: visible)
            if !ranges.isEmpty {
                ThreadSearchHighlightedAssistantMessage(text: visible, ranges: ranges)
            } else {
                let saved = UUID(uuidString: suffix).flatMap { id in workspace.messages.first { $0.id == id } }
                AssistantMessageView(text: text, allowsReadAloud: false,
                    attachments: saved.map { AttachmentChipItem.items(in: $0.parts) } ?? [],
                    onOpenAttachment: { item in if let saved { openAttachment(saved, item) } })
            }
        case .event(let event):
            ThreadEventView(event: event, isLive: event.runID == liveRun?.id && workspace.isSending,
                hasError: workspace.transcriptEventsByRun[event.runID, default: []].contains { $0.kind == .error },
                onRetry: retryRun(event.runID),
                conversationID: conversationID)
            if event.kind == .toolResult { outputLinks(for: [event]) }
        case .stepGroup(let events, let isLatest):
            StepGroupView(events: events, isLatest: isLatest,
                isLive: events.first?.runID == liveRun?.id && workspace.isSending,
                hasError: events.contains { $0.kind == .error },
                liveFinishedTools: settledQuestionStatuses(runID: events.first?.runID),
                pendingApprovals: workspace.pendingApproval.map { [$0.cardRequest] } ?? [],
                decisions: decisions, conversationID: conversationID,
                approvalPresentation: { _ in nil })
            outputLinks(for: events)
        case .terminal(let event):
            TerminalEventRow(event: event)
        case .missingFinalMessage:
            MissingFinalMessageRow()
        case .liveReasoning:
            ReasoningBlockView(text: workspace.liveReasoning, isStreaming: true)
        case .liveAssistantTail:
            AssistantMessageView(text: workspace.streamedText, isStreaming: true, allowsReadAloud: false)
        case .liveThinking:
            ModelResponseWaitingView(title: RunStateLocalizer.responseWaitingTitle(for: liveRun?.state))
        case .approval:
            EmptyView() // The review stays above the composer on Mac.
        }
    }

    private func settledQuestionStatuses(runID: UUID?) -> [String: String] {
        guard let runID else { return [:] }
        return workspace.settledQuestions[runID, default: []].reduce(into: [:]) { statuses, request in
            if request.state == .settled { statuses[request.toolCallID] = "ok" }
            if request.state == .cancelled { statuses[request.toolCallID] = "cancelled" }
        }
    }

    @ViewBuilder private func userMessage(_ message: PersistedMessage) -> some View {
        if let confirmation = PlanConfirmationSnapshot.from(message: message) {
            ConfirmedPlanMessageCard(snapshot: confirmation, onRetryStart: retryPlan(confirmation))
        } else {
            let visible = query.isEmpty ? "" : ConversationSearchText.visibleText(role: "user", content: message.content)
            let ranges = query.ranges(in: visible)
            Group {
                if ranges.isEmpty {
                    UserMessageBubble(text: message.content, attachments: AttachmentChipItem.items(in: message.parts),
                        onOpenAttachment: { item in openAttachment(message, item) })
                } else {
                    ThreadSearchHighlightedUserMessage(text: visible, ranges: ranges)
                }
            }
            .contextMenu {
                if let text = CredentialMessagePart.clipboardText(message.content) {
                    Button("action.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button(LocalizedStringKey(hasDraft ? "mac.workspace.appendMessage" : "mac.workspace.reuseMessage")) { reuseMessage(text) }
                        .disabled(workspace.isSending || workspace.isTerminating)
                }
            }
        }
        if let runID = message.runID, workspace.messages.first(where: { $0.role == "user" && $0.runID == runID })?.id == message.id,
           let questions = workspace.settledQuestions[runID], !questions.isEmpty {
            MacQuestionHistoryView(requests: questions)
        }
    }

    private func retryRun(_ id: UUID) -> (() -> Void)? {
        guard let run = workspace.continuableRun, run.id == id else { return nil }
        return { Task { await workspace.continueFromHistory(run) } }
    }

    @ViewBuilder private func outputLinks(for events: [RunEventRecord]) -> some View {
        if let runID = events.first?.runID, let conversationID {
            let callIDs = Set(events.compactMap { event -> String? in
                guard event.kind == .toolResult else { return nil }
                let payload = ThreadEventPayload.decode(event.payloadJSON)
                return payload["callID"] ?? payload["id"]
            })
            if !callIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(workspace.runToolActivity[runID, default: []]) { step in
                        if callIDs.contains(step.id), step.outputWorkspaceID == workspace.selectedConversationWorkspace?.id {
                            if let path = step.outputPath {
                                Button(path, systemImage: "doc") {
                                    workspace.withOutputFile(step) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                                }.help("mac.run.revealFile")
                            }
                            ForEach(step.mediaArtifacts) { artifact in
                                Button((artifact.relativePath as NSString).lastPathComponent,
                                       systemImage: artifact.mimeType.hasPrefix("video/") ? "film" : "photo") {
                                    Task {
                                        await workspace.withOutputFile(step, artifact: artifact) {
                                            NSWorkspace.shared.activateFileViewerSelecting([$0])
                                        }
                                    }
                                }
                                .help("mac.run.revealFile")
                                .accessibilityIdentifier("mac.run.artifact." + artifact.id.uuidString)
                            }
                        }
                    }
                }
                .task(id: runID) { await workspace.loadVisibleToolActivity(runID: runID, conversationID: conversationID) }
            }
        }
    }

    @MainActor private final class ProjectionCache {
        private struct Key: Equatable {
            let messages: [PersistedMessage]
            let runs: [RunRecord]
            let events: [UUID: [RunEventRecord]]
            let earlier: Set<UUID>
            let liveRunID: UUID?
            let running: Bool
            let hasText: Bool
            let hasReasoning: Bool
            let approvals: [PendingApproval]
        }

        private var key: Key?
        private var items: [ThreadTimelineItem] = []
        private var rowIDs: [String] = []
        private var decisions: [ToolDecisionAnnotation] = []

        func read(_ workspace: HostAgentWorkspace) -> (items: [ThreadTimelineItem], rowIDs: [String], decisions: [ToolDecisionAnnotation]) {
            let next = Key(messages: workspace.messages, runs: workspace.transcriptRuns, events: workspace.transcriptEventsByRun,
                earlier: workspace.earlierEventRunIDs, liveRunID: workspace.transcriptLiveRunID,
                running: workspace.isSending, hasText: !workspace.streamedText.isEmpty,
                hasReasoning: !workspace.liveReasoning.isEmpty, approvals: workspace.pendingApproval.map { [$0.cardRequest] } ?? [])
            if key != next {
                key = next
                let notices = ProposalDecisionPresentation.notices(messages: next.messages, events: next.events.values.flatMap { $0 })
                decisions = notices.compactMap(\.annotation)
                items = ThreadTimelineBuilder.buildConversation(messages: next.messages, runs: next.runs,
                    eventsByRun: next.events, liveRunID: next.liveRunID, isRunning: next.running,
                    liveStreamedText: workspace.streamedText, liveReasoningText: workspace.liveReasoning,
                    pendingApprovals: next.approvals, earlierEventRunIDs: next.earlier,
                    suppressedDecisionNoticeIDs: ProposalDecisionPresentation.standaloneSuppressionIDs(in: notices))
                rowIDs = items.map(\.id)
            }
            return (items, rowIDs, decisions)
        }
    }
}
