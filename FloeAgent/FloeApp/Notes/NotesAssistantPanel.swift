// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import FloePersistence

struct NotesAssistantPanel: View {
    let document: NoteDocument
    let store: NotesStore
    let close: () -> Void
    var pageID: UUID? = nil
    var onSaveAnswer: ((String) -> Void)? = nil
    var composerInput: ThreadComposerInput? = nil
    var onInputConsumed: (UUID) -> Void = { _ in }
    @EnvironmentObject private var environment: AppEnvironment
    @State private var conversationID: UUID?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var restarting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Floe 助手").font(.headline)
                    Label(document.title, systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("notes.assistant.restart", systemImage: "arrow.counterclockwise") {
                    Task { await restart() }
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .disabled(conversationID == nil || restarting)
                .accessibilityIdentifier("notes.assistant.restart")
                Button("关闭助手", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("notes.assistant.close")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(FloeTheme.chromeMaterial)
            Divider()
            if let failure, conversationID != nil {
                Text(failure).font(.callout).foregroundStyle(.red).padding(12)
            }
            if let conversationID {
                ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter, composerInput: composerInput, embedded: true, documentAssistant: true, onSaveToNotes: onSaveAnswer, onInputConsumed: onInputConsumed)
                    .id(conversationID)
                    .disabled(restarting)
            } else if let failure {
                ContentUnavailableView {
                    Label("助手无法打开", systemImage: "exclamationmark.bubble")
                } description: { Text(failure) } actions: { Button("重试") { attempt += 1 } }
            } else { ProgressView("正在打开助手…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: "\(document.id):\(attempt)") {
            do {
                failure = nil
                conversationID = nil
                if let existing = try await store.assistantConversation(documentID: document.id),
                   try await environment.conversationStore.conversation(id: existing) != nil {
                    try await NotesRepository.markAssistantOwnership([existing], database: environment.database)
                    try await Self.removeLegacyBootstrap(documentID: document.id, conversationID: existing, database: environment.database)
                    conversationID = existing
                    return
                }
                let conversation = try await environment.conversationCenter.createConversation(title: "手记 · \(document.title)", purpose: .notes)
                // The grant is created by this explicit native document selection. Tool arguments
                // and source text cannot broaden it. The dedicated policy permits bounded undoable document edits.
                try await store.bindAssistant(conversationID: conversation.id, documentID: document.id, canEdit: true)
                conversationID = conversation.id
            } catch { failure = error.localizedDescription }
        }
        .task(id: "\(conversationID?.uuidString ?? ""): \(pageID?.uuidString ?? "")") {
            guard let conversationID else { return }
            do { try await store.setAssistantFocus(conversationID: conversationID, documentID: document.id, pageID: pageID) }
            catch { failure = error.localizedDescription }
        }
    }

    private func restart() async {
        guard let previous = conversationID, !restarting else { return }
        restarting = true
        defer { restarting = false }
        do {
            environment.voiceInput.stop()
            try await environment.conversationCenter.stopNotesAssistant(conversationID: previous)
            let next = try await environment.conversationCenter.createConversation(
                title: "手记 · \(document.title)", purpose: .notes)
            try await store.bindAssistant(conversationID: next.id, documentID: document.id, canEdit: true)
            if let composerInput { onInputConsumed(composerInput.id) }
            conversationID = next.id
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    static func removeLegacyBootstrap(documentID: UUID, conversationID: UUID, database: DatabaseManager) async throws {
        let legacy = NotesStore.legacyAssistantBootstrap(documentID: documentID)
        try await database.writer { db in
            // Only the original unbound bootstrap row, never real run messages or attachments.
            try db.execute(sql: """
                DELETE FROM messages WHERE conversation_id=? AND role='user'
                AND run_id IS NULL AND content=?
                AND id=(SELECT id FROM messages WHERE conversation_id=? ORDER BY created_at,id LIMIT 1)
                AND NOT EXISTS(SELECT 1 FROM message_parts WHERE message_id=messages.id)
                """, arguments: [conversationID.uuidString, legacy, conversationID.uuidString])
        }
    }

}
#endif
