// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import QuickLook
import FloeCore
import FloePersistence
import FloeModels
import FloeNotes

/// One persisted work conversation; presentation never chooses a read/edit mode.
struct StudioAssistantView: View {
    let record: PersonalContentRecord
    var onClose: (() -> Void)? = nil
    var embedded = false
    var showsMeetingHelp = true
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var conversationID: UUID?
    @State private var diagnostic: String?
    @State private var restarting = false
    @State private var showingArchive = false

    var body: some View {
        Group {
            if embedded {
                assistantContent
            } else {
                NavigationStack {
                    assistantContent
                        .navigationTitle(title + " · " + record.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(IDELanguageRunText.t("完成", "Done")) {
                                    if let onClose { onClose() } else { dismiss() }
                                }
                            }
                        }
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showingArchive) {
            EditorAssistantArchiveView(owner: .file(record.id), center: environment.conversationCenter)
        }
        .task { await prepare() }
    }
    private var title: String {
        record.kind == .meeting ? IDELanguageRunText.t("会议助手", "Meeting assistant")
            : IDELanguageRunText.t("作品助手", "Work assistant")
    }
    private var assistantContent: some View {
        VStack(spacing: 0) {
            if let conversationID {
                HStack {
                    Spacer()
                    Menu {
                        Button("notes.assistant.restart", systemImage: "arrow.counterclockwise") {
                            Task { await restart(conversationID) }
                        }.disabled(restarting)
                        Button(IDELanguageRunText.t("归档会话", "Archived conversations"), systemImage: "archivebox") {
                            showingArchive = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(IDELanguageRunText.t("助手会话", "Assistant conversations"))
                    .accessibilityIdentifier("studio.assistant.sessions")
                }
                .padding(.horizontal, 12)
                if let diagnostic { Text(diagnostic).font(.callout).foregroundStyle(.red).padding(8) }
            }
            if record.kind == .meeting && showsMeetingHelp {
                Text(IDELanguageRunText.t("可回答会议问题、整理笔记和待办", "Ask about the meeting or organize notes and to-dos"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Group {
                if let conversationID {
                    ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter,
                        embedded: true, documentAssistant: true, ownsNavigationTitle: false)
                        .id(conversationID)
                        .disabled(restarting)
                } else if let diagnostic {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("助手暂未打开", "Unable to open assistant"), systemImage: "exclamationmark.triangle")
                    } description: { Text(diagnostic) } actions: {
                        Button(IDELanguageRunText.t("重试", "Retry")) { Task { await prepare() } }
                    }
                } else { ProgressView() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.assistant.content")
    }
    @MainActor private func restart(_ previous: UUID) async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        do {
            environment.voiceInput.stop()
            let next = try await environment.studioCoordinator.restartAssistant(for: record, expectedConversationID: previous)
            guard conversationID == previous else { return }
            conversationID = next
            diagnostic = nil
        } catch { diagnostic = error.localizedDescription }
    }

    @MainActor private func prepare() async {
        diagnostic = nil
        do {
            let id = try await environment.studioCoordinator.assistant(for: record)
            try Task.checkCancellation()
            conversationID = id
        } catch is CancellationError { }
        catch { diagnostic = error.localizedDescription }
    }
}

/// File-specific archive; never queries or presents ordinary chat history.
struct EditorAssistantArchiveView: View {
    let owner: ConversationEditorOwnership?
    let noteDocumentID: UUID?
    let notesStore: NotesStore?
    let center: ConversationCenter
    init(owner: ConversationEditorOwnership, center: ConversationCenter) {
        self.owner = owner; self.noteDocumentID = nil; self.notesStore = nil; self.center = center
    }
    init(noteDocumentID: UUID, store: NotesStore, center: ConversationCenter) {
        self.owner = nil; self.noteDocumentID = noteDocumentID; self.notesStore = store; self.center = center
    }
    @Environment(\.dismiss) private var dismiss
    @State private var records: [ConversationRecord] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if records.isEmpty && error == nil {
                    Text(IDELanguageRunText.t("暂无归档会话", "No archived conversations"))
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    NavigationLink {
                        EditorAssistantArchivedHistory(record: record, environment: center.environment)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.title)
                            Text(record.archivedAt ?? record.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(IDELanguageRunText.t("此文件的归档会话", "This file’s archived conversations"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } } }
            .task {
                do {
                    if let owner {
                        if owner.kind == .canvas {
                            records = try await center.environment.conversationStore.editorConversations(kind: .canvas, containerID: owner.containerID).filter { $0.archivedAt != nil }
                        } else {
                            records = try await center.environment.conversationStore.editorConversations(owner: owner).filter { $0.archivedAt != nil }
                        }
                    } else if let noteDocumentID {
                        guard let notes = notesStore else { throw NoteError.resourceUnavailable }
                        var history: [ConversationRecord] = []
                        for id in try await notes.assistantHistory(documentID: noteDocumentID) {
                            if let row = try await center.environment.conversationStore.conversation(id: id),
                               row.purpose == .notes, row.archivedAt != nil { history.append(row) }
                        }
                        records = ConversationListOrdering.sorted(history)
                    }
                }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

/// Persisted passive content only. No conversation controller, composer,
/// approval/question cards, retry/continue, permission editor or tool widgets.
struct EditorAssistantArchivedHistory: View {
    let record: ConversationRecord
    let environment: AppEnvironment
    @State private var messages: [PersistedMessage] = []
    @State private var runs: [RunRecord] = []
    @State private var runEvents: [UUID: [RunEventRecord]] = [:]
    @State private var cursor: ConversationMessageCursor?
    @State private var hasEarlier = false
    @State private var loading = false
    @State private var error: String?
    @State private var previewURL: URL?
    @StateObject private var workspace: WorkspaceCenter

    init(record: ConversationRecord, environment: AppEnvironment) {
        self.record = record; self.environment = environment
        _workspace = StateObject(wrappedValue: WorkspaceCenter(environment: environment, publishesSharedState: false))
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if hasEarlier { Button(IDELanguageRunText.t("更早的消息", "Earlier messages")) { Task { await load() } }.disabled(loading) }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message.role == "user" ? IDELanguageRunText.t("你", "You") : IDELanguageRunText.t("助手", "Assistant"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(message.content).textSelection(.enabled)
                        AttachmentChipRow(items: AttachmentChipItem.items(in: message.parts), alignment: .leading,
                            onOpen: { item in Task { await preview(message: message, attachmentID: item.attachmentID) } })
                    }
                }
                ForEach(runs) { run in
                    DisclosureGroup(IDELanguageRunText.t("运行详情：", "Run details: ") + run.goal) {
                        ForEach(runEvents[run.id] ?? []) { event in
                            Text(event.payloadJSON).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        .task {
                            if runEvents[run.id] == nil {
                                do { runEvents[run.id] = try await environment.runStore.events(runID: run.id) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(record.title)
        .quickLookPreview($previewURL)
        .task {
            if messages.isEmpty { await load() }
            do { runs = try await environment.runStore.recentRuns(conversationID: record.id, limit: 100) }
            catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await environment.conversationStore.messagePage(conversationID: record.id, before: cursor, limit: 100)
            messages = page.messages + messages
            cursor = page.earlierCursor; hasEarlier = page.hasEarlier
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func preview(message: PersistedMessage, attachmentID: UUID?) async {
        do {
            let request = ChatAttachmentOpenRequest(conversationID: record.id, messageID: message.id, attachmentID: attachmentID)
            let path = try await ChatAttachmentOpenAdapter.prepare(request, store: environment.conversationStore,
                resolveURL: { try environment.filesCenter.resolveURL(for: $0) }, workspace: workspace)
            guard let service = workspace.fileService else { throw ChatAttachmentOpenError.unavailable }
            previewURL = try service.guardResolver.resolve(path)
        } catch { self.error = error.localizedDescription }
    }
}
#endif
