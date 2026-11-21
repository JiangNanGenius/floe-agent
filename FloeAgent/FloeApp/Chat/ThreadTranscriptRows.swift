// SPDX-License-Identifier: MPL-2.0

import FloeAgentRuntime
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
