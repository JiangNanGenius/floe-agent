// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeMeetings
import FloeNotes
import FloePersistence
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeApp

@Suite("Current meeting notebook tools", .serialized)
@MainActor struct StudioMeetingNotesContractTests {
    private struct Fixture {
        let record: PersonalContentRecord
        let directory: URL
        let notesRoot: URL
        let store: NotesStore
        let session: MeetingProjectSession
        let context: ToolContext
        let foreign: ToolContext
    }
    private struct Page {
        let revision: String
        let state: Data
        let note: NoteDocument
        let guide: String
    }
    private func call(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let data = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(data) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func read(_ id: UUID, context: ToolContext) async throws -> Page {
        var offset = 0, text = "", revision: String?
        for _ in 0..<64 {
            let output = try await call("studio.read", ["projectID": id.uuidString, "offset": offset, "limit": 1024], context)
            let current = try #require(output["revision"] as? String)
            if let revision { try #require(revision == current) } else { revision = current }
            text += try #require(output["contentJSON"] as? String)
            guard let next = output["nextOffset"] as? Int else {
                let data = Data(text.utf8)
                return Page(revision: current, state: data,
                    note: try StudioMeetingNotesContract.expectedNotebook(inState: data),
                    guide: try #require(output["editFormat"] as? String))
            }
            try #require(next > offset); offset = next
        }
        throw PersonalContentError.changedDocument
    }
    private func append(_ fixture: Fixture, page: Page, text: String, context: ToolContext? = nil) async throws {
        let command = try JSONSerialization.data(withJSONObject: ["action": "note", "text": text])
        _ = try await call("studio.edit", ["projectID": fixture.record.id.uuidString,
            "expectedRevision": page.revision, "operationsJSON": String(decoding: command, as: UTF8.self)], context ?? fixture.context)
    }
    private func body(_ note: NoteDocument) -> String { note.pages.flatMap(\.elements).map(\.text).joined() }
    private func withMeeting(_ action: @MainActor (Fixture) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("studio-meeting-contract-\(UUID())")
        let notesRoot = temporary.appendingPathComponent("Notes")
        let previous = try await NotesRepository.shared.existingStore()
        let store = try NotesStore(root: notesRoot)
        await NotesRepository.shared.setStoreOverride(store)
        var record: PersonalContentRecord?, directory: URL?, conversations: [UUID] = []
        @MainActor func cleanup() async {
            if let record { await MeetingProjectSession.prepareForDeletion(id: record.id) }
            for id in conversations { try? await environment.conversationStore.deleteConversation(id: id) }
            await NotesRepository.shared.setStoreOverride(previous)
            if let directory { try? FileManager.default.removeItem(at: directory) }
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            let created = try await PersonalContentService.shared.create(kind: .meeting,
                title: "Synthetic meeting contract \(UUID().uuidString.prefix(8))")
            record = created
            let location = try await PersonalContentService.shared.library().resolve(created.id)
            directory = location.url
            let session = try await MeetingProjectSession.open(id: created.id,
                directory: location.url.appendingPathComponent("Meeting"), environment: environment)
            let bound = try await environment.studioCoordinator.assistant(for: created)
            conversations.append(bound)
            let foreign = UUID(), now = Date()
            conversations.append(foreign)
            try await environment.conversationStore.saveConversation(.init(id: foreign, title: "Unbound meeting task", createdAt: now, updatedAt: now))
            _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: foreign, title: "Unbound meeting task")
            try await environment.conversationStore.setArchived(id: foreign, archived: true)
            var contexts: [ToolContext] = []
            for conversation in [bound, foreign] {
                let run = UUID()
                try await environment.runStore.saveRun(.init(id: run, conversationID: conversation,
                    state: "executing", goal: "Edit synthetic current meeting notes only", startedAt: now))
                var context = ToolContext(runID: run, toolCallID: UUID().uuidString,
                    allowedToolNames: StudioCoordinator.names, cancellation: CancellationToken(), conversationID: conversation)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                context.approvalGrantID = UUID(); contexts.append(context)
            }
            try await action(Fixture(record: created, directory: location.url, notesRoot: notesRoot,
                store: store, session: session, context: contexts[0], foreign: contexts[1]))
        } catch { await cleanup(); throw error }
        await cleanup()
    }

    @Test func registeredDiscoveryAndNativeContextLeadToTheSameSavedMeetingNotebook() async throws {
        try await withMeeting { fixture in
            let descriptors = ToolCatalog.allDescriptors
            for query in ["当前会议", "会议笔记", "meeting notes"] {
                let names = Set(ToolDiscovery.matches(query: query, descriptors: descriptors).map(\.name))
                #expect(names.isSuperset(of: ["studio.list", "studio.read", "studio.edit"]))
            }
            let environment = FloeAgentApp.liveEnvironment
            let conversation = try #require(fixture.context.conversationID)
            let context = try await environment.studioCoordinator.workRuntimeContext(conversationID: conversation,
                runID: fixture.context.runID, temporary: false, availableToolNames: StudioCoordinator.names)
            #expect(context?.contains(fixture.record.id.uuidString) == true)
            #expect(context?.contains("studio.list") == true)
            #expect(context?.contains("notes.read is the ordinary Notes selection") == true)
            #expect(context?.contains(fixture.record.title) == false)
            #expect(try await environment.studioCoordinator.workRuntimeContext(conversationID: conversation,
                runID: fixture.foreign.runID, temporary: false, availableToolNames: StudioCoordinator.names) == nil)
            let readOnlyHint = try await environment.studioCoordinator.workRuntimeContext(conversationID: conversation,
                runID: fixture.context.runID, temporary: false, availableToolNames: ["studio.list", "studio.read"])
            #expect(readOnlyHint?.contains("studio.edit") == false)
            #expect(try await environment.studioCoordinator.workRuntimeContext(conversationID: conversation,
                runID: fixture.context.runID, temporary: true, availableToolNames: StudioCoordinator.names) == nil)
            #expect(try await environment.studioCoordinator.workRuntimeContext(conversationID: conversation,
                runID: fixture.context.runID, temporary: false, availableToolNames: []) == nil)
            #expect(try await environment.studioCoordinator.workRuntimeContext(conversationID: try #require(fixture.foreign.conversationID),
                runID: fixture.foreign.runID, temporary: false, availableToolNames: StudioCoordinator.names) == nil)
            let list = try await call("studio.list", [:], fixture.context)
            #expect(list["activeProjectID"] as? String == fixture.record.id.uuidString)
            let before = try await read(fixture.record.id, context: fixture.context)
            #expect(before.guide.contains("note"))
            let unrelated = try await fixture.store.create(NoteDocument(title: "Independent ordinary Notes original"))
            let text = "负责人张三：蓝杉47，周一初稿。\n李四：预算200元。\n下次会议：周二。"
            try await append(fixture, page: before, text: text)
            let after = try await read(fixture.record.id, context: fixture.context)
            #expect(after.note.id == before.note.id)
            #expect(after.note.revision == before.note.revision + 1)
            #expect(body(after.note).contains(text))
            #expect(fixture.session.notebook.document?.id == before.note.id)
            #expect(fixture.session.notebook.document?.revision == after.note.revision)
            #expect(try await fixture.store.document(unrelated.id) == unrelated)
            // A fresh SQLite reader, not the session cache, proves persistence.
            let reopened = try NotesStore(root: fixture.notesRoot)
            #expect(try await reopened.document(after.note.id) == after.note)
            #expect(try await reopened.historyState(after.note.id).canUndo == true)
            #expect(try await fixture.session.service.sessions(meeting: MeetingID(fixture.record.id)).isEmpty)
            #expect(try await fixture.session.service.transcript(meeting: MeetingID(fixture.record.id)).isEmpty)
        }
    }

    @Test func staleForeignTemporaryAndCancelledEditsPreserveTheExactOriginal() async throws {
        try await withMeeting { fixture in
            let before = try await read(fixture.record.id, context: fixture.context)
            let manual = try await fixture.store.apply(.init(documentID: before.note.id,
                expectedRevision: before.note.revision, title: "Synthetic manual edit", edits: [.rename("Manual meeting notebook")]))
            let fresh = try await read(fixture.record.id, context: fixture.context)
            #expect(fresh.note == manual)
            do { try await append(fixture, page: before, text: "stale forbidden")
                Issue.record("A stale inspected revision appended meeting text")
            } catch PersonalContentError.changedDocument {}
            do { try await append(fixture, page: fresh, text: "foreign forbidden", context: fixture.foreign)
                Issue.record("An unbound task appended this meeting notebook")
            } catch let FloeError.validationFailed(message) { #expect(message.contains("Open this work")) }
            var temporary = fixture.context; temporary.temporaryReadOnly = true
            do { try await append(fixture, page: fresh, text: "temporary forbidden", context: temporary)
                Issue.record("Temporary chat edited meeting notes")
            } catch let FloeError.validationFailed(message) { #expect(message.contains("saved task")) }
            var cancelled = fixture.context; cancelled.cancellation = CancellationToken(); cancelled.cancellation.cancel()
            do { try await append(fixture, page: fresh, text: "cancelled forbidden", context: cancelled)
                Issue.record("A cancelled task appended meeting notes")
            } catch FloeError.cancelled {} catch is CancellationError {}
            #expect(try await fixture.store.document(before.note.id) == manual)
            // Rebinding the link cannot redirect an old session's write authority.
            let other = try await fixture.store.create(NoteDocument(title: "Different notebook original"))
            let link = fixture.session.root.appendingPathComponent("personal-note.json")
            let originalLink = try Data(contentsOf: link)
            try JSONEncoder().encode(other.id).write(to: link, options: .atomic)
            do { try await StudioMeetingNotesContract.append(session: fixture.session, expected: manual,
                text: "wrong notebook forbidden", requestID: UUID(), cancellation: CancellationToken())
                Issue.record("A replaced native link redirected an inspected meeting write")
            } catch PersonalContentError.changedDocument {}
            try originalLink.write(to: link, options: .atomic)
            #expect(try await fixture.store.document(other.id) == other)
            #expect(try await fixture.store.document(before.note.id) == manual)
        }
    }

    @Test func inspectionDoesNotCreateAMissingNotebookOrReuseAnotherRootSession() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-read-only-\(UUID())")
        let previous = try await NotesRepository.shared.existingStore()
        let store = try NotesStore(root: temporary.appendingPathComponent("Notes"))
        await NotesRepository.shared.setStoreOverride(store)
        var meetingID: UUID?
        @MainActor func cleanup() async {
            if let meetingID { await MeetingProjectSession.prepareForDeletion(id: meetingID) }
            await NotesRepository.shared.setStoreOverride(previous)
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            let content = PersonalContentService(root: temporary.appendingPathComponent("Library"))
            let record = try await content.create(kind: .meeting, title: "Synthetic missing notebook")
            meetingID = record.id
            let location = try await content.library().resolve(record.id)
            let root = location.url.appendingPathComponent("Meeting")
            let session = try await MeetingProjectSession.open(id: record.id, directory: root,
                environment: FloeAgentApp.liveEnvironment, createNotebookIfMissing: false)
            let before = try await store.documents(includeTrash: true)
            do { _ = try await StudioMeetingNotesContract.read(session: session, cancellation: CancellationToken())
                Issue.record("Inspection fabricated a missing notebook")
            } catch { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("personal-note.json").path)) }
            #expect(try await store.documents(includeTrash: true) == before)
            let other = temporary.appendingPathComponent("DifferentMeeting")
            do { _ = try await MeetingProjectSession.open(id: record.id, directory: other,
                environment: FloeAgentApp.liveEnvironment, createNotebookIfMissing: false)
                Issue.record("The same meeting ID reused a cached session from another root")
            } catch PersonalContentError.changedDocument {}
            // Native MeetingProjectView still invokes this first-open path.
            await session.loadNotebook()
            let opened = try #require(session.notebook.document)
            #expect(try await store.document(opened.id) == opened)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("personal-note.json").path))
        } catch { await cleanup(); throw error }
        await cleanup()
    }
}
#endif
