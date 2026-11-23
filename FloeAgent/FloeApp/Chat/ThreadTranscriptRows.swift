// SPDX-License-Identifier: MPL-2.0

import FloeAgentRuntime
import FloeCore
import FloeModels
import FloePersistence
import SwiftUI

struct ThreadTimelineRows<Row: View>: View {
    let items: [ThreadTimelineItem]
    let rowIDs: [String]
    let isRunning: Bool
    @ViewBuilder let row: (ThreadTimelineItem) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(items) { item in
            datedRow(item)
                .id(item.id)
                .transition(isRunning ? FloeTheme.stepTransition(reduceMotion: reduceMotion) : .identity)
        }
        .animation(isRunning && !reduceMotion ? .easeOut(duration: 0.22) : nil, value: rowIDs)
    }

    @ViewBuilder private func datedRow(_ item: ThreadTimelineItem) -> some View {
        switch item {
        case .userMessage(let message):
            VStack(alignment: .trailing, spacing: 2) {
                row(item)
                ChatMessageFooter(sentAt: message.createdAt, messageID: message.id.uuidString,
                    userText: PlanConfirmationSnapshot.from(message: message) == nil ? message.content : nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistantMessage(_, let id, let sentAt):
            VStack(alignment: .leading, spacing: 2) {
                row(item)
                ChatMessageFooter(sentAt: sentAt, messageID: id)
            }
        default:
            row(item)
        }
    }
}

enum ThreadTimelineMessageLocation {
    /// A persisted reply is sometimes rendered from its corresponding run
    /// event. Match the visible answer in that exact run before moving the reader.
    static func rowID(for messageID: UUID, items: [ThreadTimelineItem], messages: [PersistedMessage],
                      eventsByRun: [UUID: [RunEventRecord]]) -> String? {
        let userID = "user.\(messageID.uuidString)"
        let assistantID = "assistant.\(messageID.uuidString)"
        if let directlyRendered = items.first(where: { $0.id == userID || $0.id == assistantID }) {
            return directlyRendered.id
        }
        guard let message = messages.first(where: { $0.id == messageID }), message.role == "assistant",
              let runID = message.runID else { return nil }
        let answerIDs = Set(eventsByRun[runID, default: []].lazy.filter { $0.kind == .assistantText }.map(\.id))
        let visible = ConversationSearchText.visibleText(markdown: message.content)
        return items.first { item in
            guard case .assistantMessage(let text, let suffix, _) = item, let eventID = UUID(uuidString: suffix),
                  answerIDs.contains(eventID) else { return false }
            return ConversationSearchText.visibleText(markdown: text) == visible
        }?.id
    }
}

/// The terminal marker row: a single quiet status line, always rendered
/// after the final assistant reply. No big card, no raw machine names —
/// the stop reason resolves through RunStateLocalizer.
struct TerminalEventRow: View {
    let event: RunEventRecord

    private var state: String {
        ThreadEventPayload.decode(event.payloadJSON)["stopReason"] ?? "completed"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state == "completed" || state == "endTurn"
                ? "checkmark.circle" : "stop.circle")
                .foregroundStyle(RunStateLocalizer.color(for: "completed"))
                .accessibilityHidden(true)
            Text(RunStateLocalizer.terminalTitle(stopReason: state))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Spacer()
            Text(event.createdAt, style: .time)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.terminal")
    }
}

/// A completed run that produced no final assistant text is an explicit,
/// honest failure surface — never silent.
struct MissingFinalMessageRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("thread.no_final_reply")
                .font(FloeTheme.Typography.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.no_final_reply")
    }
}

/// The user's own text with every find term highlighted. Mirrors the normal
/// user bubble; only the rendering path changes while find is active.
struct ThreadSearchHighlightedUserMessage: View {
    let text: String
    let ranges: [Range<Int>]

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)
            Text(ThreadSearchText.highlighted(text, ranges: ranges))
                .font(FloeTheme.Typography.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    FloeTheme.primary.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "thread.role.user"))
    }
}

/// The assistant's visible answer with every find term highlighted. Rich
/// Markdown blocks are temporarily rendered as their flattened visible text so
/// the highlight cannot drift between source and display offsets.
struct ThreadSearchHighlightedAssistantMessage: View {
    let text: String
    let ranges: [Range<Int>]

    var body: some View {
        Text(ThreadSearchText.highlighted(text, ranges: ranges))
            .font(FloeTheme.Typography.body)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "thread.role.assistant"))
    }
}

struct PendingInputQueueView: View {
    #if FLOE_MAC_HOST_SMOKE
    static var smokeMenuFrames: [UUID: CGRect] = [:]
    #endif

    let inputs: [PendingUserInput]
    let canSteer: Bool
    let onEdit: (PendingUserInput) -> Void
    let onDelete: (PendingUserInput) -> Void
    let onMove: (PendingUserInput, Int) -> Void
    let onSteer: (PendingUserInput) -> Void
    let onDemote: (PendingUserInput) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("chat.thread_detail_view.message_queue", systemImage: "text.badge.plus")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(inputs.count)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayText(for: input))
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(input.executionMode == "browserHandoff" && input.status == .queued
                            ? localized("通知已保存至原任务，可在浏览器中继续任务", "Saved to the original task; continue from the browser")
                            : statusTitle(input.status))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(input.status == .queued ? .secondary : FloeTheme.pending)
                    }
                    Spacer(minLength: 4)
                    if input.executionMode == "browserHandoff" {
                        Image(systemName: "safari").foregroundStyle(.secondary)
                    } else if input.status == .queued || input.status == .steerPending {
                        let queuedIndex = queuedInputs.firstIndex(where: { $0.id == input.id })
                        Menu {
                            Button("workspace.workspace_canvas_view.edit", systemImage: "pencil") { onEdit(input) }
                            Button("chat.thread_detail_view.move_up", systemImage: "arrow.up") { onMove(input, -1) }
                                .disabled(queuedIndex == nil || queuedIndex == queuedInputs.startIndex)
                            Button("chat.thread_detail_view.move_down", systemImage: "arrow.down") { onMove(input, 1) }
                                .disabled(queuedIndex == nil || queuedIndex == queuedInputs.indices.last)
                            // Both directions come from one policy: a queued
                            // row can steer into the active run, a pending
                            // steer can return to the queue — but only while
                            // it has NOT been consumed. Consumed rows offer
                            // no mode action at all.
                            let modeActions = RunningInputModePolicy.modeActions(
                                status: input.status, canSteer: canSteer)
                            if modeActions.contains(.promoteToSteer) {
                                Button("chat.thread_detail_view.convert_to_steer", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                    onSteer(input)
                                }
                                .disabled(!canSteer)
                            }
                            if modeActions.contains(.demoteToQueue) {
                                Button(demoteToQueueText, systemImage: "arrow.uturn.left") {
                                    onDemote(input)
                                }
                            }
                            Divider()
                            Button("workspace.workspace_canvas_view.delete", systemImage: "trash", role: .destructive) { onDelete(input) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        }
                        #if os(macOS)
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        #endif
                        .accessibilityLabel("chat.thread_detail_view.queue_message_action")
                        .accessibilityIdentifier("thread.pendingInputs.actions.\(input.id.uuidString)")
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { Self.smokeMenuFrames[input.id] = $0 })
                        #endif
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.pendingInputs")
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        FloeL10n.isChinese ? chinese : english
    }

    private var queuedInputs: [PendingUserInput] {
        inputs.filter { $0.status == .queued }
    }

    /// Central-catalog entry for this action has not landed yet; keep the
    /// menu bilingual and reviewable in both languages for now.
    private var demoteToQueueText: String {
        localized("转为排队", "Back to queue")
    }

    /// A trusted internal notice steer (design-assistant confirmation or
    /// structured proposal decision) shows the concise localized summary
    /// instead of the raw grant/target/identity payload. A validated proposal
    /// decision uses its decision-specific sentence. Every other input is
    /// untouched.
    private func displayText(for input: PendingUserInput) -> String {
        if let decisionSummary = ProposalDecisionPresentation.summary(for: input) {
            return decisionSummary
        }
        if let summary = InternalNoticeProjection.userFacingSummary(for: input) {
            return summary
        }
        return input.executionMode == "browserHandoff"
            ? localized("浏览器控制权已交还", "Browser control returned")
            : input.content
    }

    private func statusTitle(_ status: PendingUserInputStatus) -> String {
        switch status {
        case .queued: FloeL10n.l("chat.thread_detail_view.wait_for_the_current_run_to")
        case .promoting: FloeL10n.l("chat.thread_detail_view.converting_to_steer")
        case .steerPending: FloeL10n.l("chat.thread_detail_view.waiting_for_a_safe_insertion_point")
        case .consumed: FloeL10n.l("chat.thread_detail_view.sent")
        case .cancelled: FloeL10n.l("chat.thread_detail_view.cancelled")
        }
    }
}

struct PendingInputEditor: View {
    #if FLOE_MAC_HOST_SMOKE
    static var smokeSaveFrame: CGRect?
    #endif

    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(input: PendingUserInput, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: input.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                TextEditor(text: $text)
                    .frame(minHeight: 125)
                    .accessibilityLabel("chat.thread_detail_view.queue_message")
                #else
                TextField("chat.thread_detail_view.queue_message", text: $text, axis: .vertical)
                    .lineLimit(3...10)
                #endif
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("chat.thread_detail_view.edit_queue_message")
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Spacer()
                        cancelButton
                        saveButton.buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                }
                .background(.regularMaterial)
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { cancelButton }
                ToolbarItem(placement: .confirmationAction) { saveButton }
            }
            #endif
        }
        #if !os(macOS)
        .presentationDetents([.medium])
        #endif
    }

    private var cancelButton: some View {
        Button("workspace.workspace_canvas_view.cancel", role: .cancel) { dismiss() }
            .accessibilityIdentifier("thread.pendingInputs.edit.cancel")
    }

    private var saveButton: some View {
        Button("workspace.workspace_canvas_view.save") {
            onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        }
        .accessibilityIdentifier("thread.pendingInputs.edit.save")
        .keyboardShortcut(.defaultAction)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { Self.smokeSaveFrame = $0 })
        #endif
    }
}
