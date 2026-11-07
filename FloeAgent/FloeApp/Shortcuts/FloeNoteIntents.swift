// SPDX-License-Identifier: MPL-2.0
#if canImport(AppIntents) && canImport(UIKit)
import AppIntents
import Foundation
import GRDB
import FloeCore
import FloeNotes
import FloePersistence

/// Explicit references are rehydrated without enumerating private content.
/// Titles and dates are read only by the authenticated search action.
struct FloeNoteEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "shortcuts.note.entity")
    static let defaultQuery = FloeNoteEntityQuery()
    let id: String
    @Property(title: "shortcuts.note.title") var title: String
    @Property(title: "shortcuts.note.modified") var modifiedAt: Date?

    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }

    init(id: UUID, title: String, modifiedAt: Date? = nil) {
        self.id = id.uuidString
        self.title = title
        self.modifiedAt = modifiedAt
    }

    init(_ document: NoteDocument) {
        self.init(id: document.id, title: document.title, modifiedAt: document.updatedAt)
    }
}

struct FloeNoteEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FloeNoteEntity] {
        identifiers.compactMap { UUID(uuidString: $0) }.map {
            FloeNoteEntity(id: $0, title: FloeL10n.l("shortcuts.note.entity"))
        }
    }
    func suggestedEntities() async throws -> [FloeNoteEntity] { [] }
}

@MainActor
enum FloeNoteIntentService {
    static func ready(_ environment: AppEnvironment) async throws {
        guard AppleCapabilityPreferences.isEnabled(.shortcuts) else {
            throw FloeShortcutRunError.shortcutsCapabilityDisabled
        }
        try await environment.ensureDurableAutomationReady()
        try Task.checkCancellation()
    }

    static func existingStore() async throws -> NotesStore? {
        try await NotesRepository.shared.existingStore()
    }

    static func create(text: String, title: String?, notebook: String?,
                       store suppliedStore: NotesStore? = nil) async throws -> NoteDocument {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NoteError.invalidOperation(FloeL10n.l("shortcuts.note.empty")) }
        let store: NotesStore
        if let suppliedStore { store = suppliedStore }
        else { store = try await NotesRepository.shared.store() }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var notebookID: UUID?
        if let notebook = notebook?.trimmingCharacters(in: .whitespacesAndNewlines), !notebook.isEmpty {
            let matches = try await store.notebooks().filter { $0.title.localizedCaseInsensitiveCompare(notebook) == .orderedSame }
            guard matches.count == 1 else {
                throw NoteError.invalidOperation(FloeL10n.l("shortcuts.note.notebook_unavailable"))
            }
            notebookID = matches[0].id
        }
        var document = NoteDocument(notebookID: notebookID,
            title: name.flatMap { $0.isEmpty ? nil : $0 } ?? String(body.prefix(60)))
        guard body.utf8.count <= 2_000_000 else {
            throw NoteError.invalidOperation(FloeL10n.l("notes.note_file_importer.the_text_file_exceeds_2_mb"))
        }
        document.pages = NotesTextLayout.pages(text: body, source: nil)
        if document.pages.isEmpty { document.pages = [NotePage()] }
        try Task.checkCancellation()
        return try await store.create(document)
    }
}

struct CreateFloeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.note.create"
    static let description = IntentDescription("shortcuts.note.create_description")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "shortcuts.note.text") var text: String
    @Parameter(title: "shortcuts.note.title") var noteTitle: String?
    @Parameter(title: "shortcuts.note.notebook") var notebook: String?
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FloeNoteEntity> & ProvidesDialog {
        try await FloeNoteIntentService.ready(environment)
        let saved = try await FloeNoteIntentService.create(text: text, title: noteTitle, notebook: notebook)
        return .result(value: FloeNoteEntity(saved),
            dialog: IntentDialog("\(FloeL10n.l("shortcuts.note.saved", saved.title))"))
    }
}

struct FindFloeNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.note.find"
    static let description = IntentDescription("shortcuts.note.find_description")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "shortcuts.note.query") var query: String
    @Parameter(title: "shortcuts.note.after") var modifiedAfter: Date?
    @Parameter(title: "shortcuts.note.before") var modifiedBefore: Date?
    @Parameter(title: "shortcuts.note.limit", default: 20) var limit: Int
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[FloeNoteEntity]> {
        try await FloeNoteIntentService.ready(environment)
        guard let store = try await FloeNoteIntentService.existingStore() else {
            return .result(value: [FloeNoteEntity]())
        }
        let documents = try await store.search(query, limit: min(50, max(1, limit)),
            modifiedAfter: modifiedAfter, modifiedBefore: modifiedBefore)
        return .result(value: documents.map(FloeNoteEntity.init))
    }
}

struct OpenFloeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.note.open"
    static let description = IntentDescription("shortcuts.note.open_description")
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "shortcuts.note.entity") var note: FloeNoteEntity
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        try await FloeNoteIntentService.ready(environment)
        guard let id = UUID(uuidString: note.id),
              let store = try await FloeNoteIntentService.existingStore() else { throw NoteError.notFound }
        let document = try await store.document(id)
        guard document.deletedAt == nil else { throw NoteError.notFound }
        return .result(opensIntent: OpenURLIntent(FloeAppEntryRoute.note(id).url))
    }
}

struct FindFloeRunsIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.run.find.title"
    static let description = IntentDescription("shortcuts.run.find.description")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "shortcuts.note.query") var name: String
    @Parameter(title: "shortcuts.note.limit", default: 20) var limit: Int
    @AppDependency private var environment: AppEnvironment

    /// The authenticated intent and tests share exactly this title query.
    /// It never enumerates Notes, hidden authoring sessions or archived tasks.
    @MainActor static func matchingConversationIDs(name:String,limit:Int,database:DatabaseManager) async throws -> [String] {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let count = min(50, max(1, limit))
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%" + escaped + "%"
        return try await database.reader { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM conversations
                WHERE purpose='ordinary' AND visibility='normal' AND archived_at IS NULL
                  AND title LIKE ? ESCAPE '\\'
                ORDER BY updated_at DESC,id LIMIT ?
                """, arguments: [pattern, count])
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[FloeShortcutRunEntity]> {
        try await FloeNoteIntentService.ready(environment)
        let count = min(50, max(1, limit))
        let identifiers = try await Self.matchingConversationIDs(name:name,limit:count,database:environment.database)
        var values: [FloeShortcutRunEntity] = []
        for rawID in identifiers {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: rawID) else { continue }
            let runs = try await environment.runStore.recentRuns(conversationID: id, limit: count)
            for run in runs {
                let value = try await FloeShortcutRunIntentBridge.snapshot(
                    runID: run.id, expectedConversationID: id, environment: { environment })
                values.append(value)
                if values.count == count { return .result(value: values) }
            }
        }
        return .result(value: values)
    }
}
#endif
