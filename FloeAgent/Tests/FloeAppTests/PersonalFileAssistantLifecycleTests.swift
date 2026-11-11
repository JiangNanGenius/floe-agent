// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
#if canImport(UIKit)
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp
#else
@testable import FileLifecycleVerify
#endif

@Suite("Personal file and assistant lifecycle", .serialized)
@MainActor struct PersonalFileAssistantLifecycleTests {
    private enum Failure: Error { case stop, file, cleanup }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-file-lifecycle-\(UUID())")
        var libraryRoot: URL { root.appendingPathComponent("Library").standardizedFileURL.resolvingSymlinksInPath() }
        let library: PersonalContentLibrary
        let access: StudioDocumentAccess
        var events: [String] = []
        var stopped: [StudioAssistantBinding] = []
        var purged: [UUID] = []
        var conversations: Set<UUID> = []
        var failStop = false, failRetire = false, failPurge = false
        init() throws {
            library = PersonalContentLibrary(root: root.appendingPathComponent("Library"))
            access = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func create(_ title: String = "Original", folders: [String] = []) async throws -> PersonalContentRecord {
            try await library.create(kind: .diagram, title: title, in: folders) { directory, _ in
                try Data("original+history\0中".utf8).write(to: directory.appendingPathComponent("original.bin"))
            }
        }
        func bind(_ record: PersonalContentRecord) async throws -> UUID {
            let id = UUID(); conversations.insert(id)
            try await access.bindAssistant(conversationID: id, projectID: record.id)
            return id
        }
        func lifecycle(access override: StudioDocumentAccess? = nil) -> PersonalFileAssistantLifecycle {
            PersonalFileAssistantLifecycle(access: override ?? access, library: library,
                stop: { bindings in
                    self.events.append("stop"); self.stopped += bindings
                    if self.failStop { throw Failure.stop }
                    return PersonalFileAssistantStopLease { self.events.append("release") }
                }, retire: { _ in
                    self.events.append("retire")
                    if self.failRetire { throw Failure.cleanup }
                }, purge: { id, _ in
                    self.events.append("purge")
                    if self.failPurge { throw Failure.cleanup }
                    self.purged.append(id); self.conversations.remove(id)
                })
        }
        func trash(_ record: PersonalContentRecord) async throws -> PersonalLibraryTrashEntry {
            try await lifecycle().perform(action: .trash, entryID: UUID(), relativePath: record.relativePath,
                members: [record]) { eventID in
                self.events.append("file")
                return try await self.library.softDelete(record, eventID: eventID)
            }
        }
    }

    @Test func trashStopsBeforeFileCommitAndRetainsExactBindingAndBytes() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        let ordinary = UUID(); f.conversations.insert(ordinary)
        try await f.access.finishCreation(conversationID: ordinary, projectID: record.id)
        let originalURL = try await f.library.resolve(record.id).url.appendingPathComponent("original.bin")
        let bytes = try Data(contentsOf: originalURL)
        let entry = try await f.trash(record)
        #expect(f.events == ["stop", "file", "retire", "release"])
        #expect(f.stopped == [.init(projectID: record.id, conversationID: assistant)])
        #expect(try await f.library.records().isEmpty)
        #expect(try Data(contentsOf: originalURL) == bytes)
        #expect(try await f.access.assistant(projectID: record.id) == assistant)
        #expect(f.conversations == [assistant, ordinary])
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        try await f.lifecycle().perform(action: .restore, entryID: entry.id, relativePath: entry.relativePath,
            members: [record]) { _ in try await f.library.restore(entry.id) }
        #expect(try await f.library.resolve(record.id).record.id == record.id)
        #expect(try await f.access.assistant(projectID: record.id) == assistant)
        #expect(f.purged.isEmpty)
        #expect(try Data(contentsOf: originalURL) == bytes)
    }

    @Test func stopFailureAndFileFailureNeverRemoveConversationOrOriginal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        f.failStop = true
        await #expect(throws: Failure.self) { _ = try await f.trash(record) }
        #expect(f.events == ["stop"])
        #expect(try await f.library.resolve(record.id).record.id == record.id)
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        f.failStop = false; f.events = []
        await #expect(throws: Failure.self) {
            try await f.lifecycle().perform(action: .trash, entryID: UUID(), relativePath: record.relativePath,
                members: [record]) { _ in throw Failure.file }
        }
        #expect(f.events == ["stop", "release"])
        #expect(f.conversations.contains(assistant))
        #expect(try await f.access.canAccess(conversationID: assistant, projectID: record.id, editing: true))
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        #expect(try await f.library.recentlyDeleted().isEmpty)
    }

    @Test func committedTrashCleanupRetriesAfterRestartAndLocksLateBinding() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        f.failRetire = true
        await #expect(throws: Failure.self) { _ = try await f.trash(record) }
        #expect(try await f.library.records().isEmpty)
        #expect(try await f.access.pendingFileLifecycles().count == 1)
        await #expect(throws: PersonalFileAssistantLifecycleError.self) {
            try await f.access.bindAssistant(conversationID: UUID(), projectID: record.id)
        }
        let reopened = try StudioDocumentAccess(root: f.root.appendingPathComponent("Authority"))
        f.failRetire = false
        try await f.lifecycle(access: reopened).reconcile()
        #expect(try await reopened.pendingFileLifecycles().isEmpty)
        #expect(try await reopened.assistant(projectID: record.id) == assistant)
        #expect(f.purged.isEmpty)
    }

    @Test func crashBetweenFileTombstoneAndCompanionCommitUsesExactEvent() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record), eventID = UUID()
        _ = try await f.access.beginFileLifecycle(action: .trash, entryID: eventID,
            rootPath: f.libraryRoot.path, relativePath: record.relativePath, members: [record])
        _ = try await f.library.softDelete(record, eventID: eventID)
        try await f.lifecycle().reconcile()
        #expect(f.events == ["stop", "retire", "release"])
        #expect(try await f.access.assistant(projectID: record.id) == assistant)
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
    }

    @Test func restoreFirstSettlesItsCommittedTrashPredecessor() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        f.failRetire = true
        await #expect(throws: Failure.self) { _ = try await f.trash(record) }
        let entry = try #require(try await f.library.recentlyDeleted().first)
        f.failRetire = false
        try await f.lifecycle().perform(action: .restore, entryID: entry.id,
            relativePath: entry.relativePath, members: [record]) { _ in try await f.library.restore(entry.id) }
        #expect(try await f.library.resolve(record.id).record.id == record.id)
        #expect(try await f.access.assistant(projectID: record.id) == assistant)
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        #expect(f.purged.isEmpty)
    }

    @Test func crashBeforeFileCommitReleasesIntentWithoutDeletingAnything() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        _ = try await f.access.beginFileLifecycle(action: .trash, entryID: UUID(),
            rootPath: f.libraryRoot.path, relativePath: record.relativePath, members: [record])
        try await f.lifecycle().reconcile()
        #expect(f.events.isEmpty)
        #expect(try await f.library.resolve(record.id).record.id == record.id)
        #expect(try await f.access.assistant(projectID: record.id) == assistant)
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
    }

    @Test func nativeCompoundDeleteUsesTheReservedTombstoneIdentity() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), eventID = UUID()
        _ = try await f.bind(record)
        // Biology's existing compound coordinator calls this same library
        // overload without an explicit event ID. It must share the intent.
        let entry = try await f.lifecycle().perform(action: .trash, entryID: eventID,
            relativePath: record.relativePath, members: [record]) { _ in try await f.library.softDelete(record) }
        #expect(entry.id == eventID)
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
    }

    @Test func partialPurgeKeepsBothJournalsAndRetriesOnlyTheConfirmedOriginal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        let entry = try await f.trash(record)
        let first = try #require(try await f.library.permanentDeletionPlans([entry]).first)
        await #expect(throws: Error.self) {
            _ = try await f.lifecycle().perform(action: .purge, entryID: entry.id,
                relativePath: entry.relativePath, members: first.members) { _ in
                try await f.library.permanentlyDelete(first) { phase in
                    if case .beforeIndexCommit = phase { throw Failure.file }
                }
            }
        }
        #expect(try await f.access.pendingFileLifecycles().count == 1)
        #expect(try await f.library.permanentDeletionPendingIDs().contains(entry.id))
        try await f.lifecycle().reconcile()
        #expect(f.purged.isEmpty)
        #expect(try await f.access.pendingFileLifecycles().count == 1)
        let retry = try #require(try await f.library.permanentDeletionPlans([entry]).first)
        _ = try await f.lifecycle().perform(action: .purge, entryID: entry.id,
            relativePath: entry.relativePath, members: retry.members) { _ in try await f.library.permanentlyDelete(retry) }
        #expect(f.purged == [assistant])
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        #expect(try await f.library.recentlyDeleted().isEmpty)
    }

    @Test func permanentCleanupUsesPositiveCommitProofAndPreservesOrdinaryTasksAndSuccessors() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create("Same title"), assistant = try await f.bind(record)
        let ordinary = UUID(); f.conversations.insert(ordinary)
        try await f.access.finishCreation(conversationID: ordinary, projectID: record.id)
        let entry = try await f.trash(record)
        let plan = try #require(try await f.library.permanentDeletionPlans([entry]).first)
        f.failPurge = true
        await #expect(throws: Failure.self) {
            _ = try await f.lifecycle().perform(action: .purge, entryID: entry.id, relativePath: entry.relativePath,
                members: plan.members) { _ in try await f.library.permanentlyDelete(plan) }
        }
        #expect(try await f.library.recentlyDeleted().isEmpty)
        #expect(try await f.access.pendingFileLifecycles().count == 1)
        let successor = try await f.create("Same title"), successorAssistant = try await f.bind(successor)
        #expect(successor.id != record.id)
        f.failPurge = false
        try await f.lifecycle().reconcile()
        #expect(f.purged == [assistant])
        #expect(f.conversations == [ordinary, successorAssistant])
        #expect(try await f.access.assistant(projectID: record.id) == nil)
        #expect(try await f.access.assistant(projectID: successor.id) == successorAssistant)
        #expect(try await !f.access.canAccess(conversationID: ordinary, projectID: record.id, editing: false))
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        #expect(try PersonalLibraryTrashStore.read(root: f.libraryRoot).assistantPurgeReceipts?.isEmpty == true)
    }

    @Test func missingPathWithoutPurgeProofPreservesUnknownConversation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), assistant = try await f.bind(record)
        let entry = try await f.trash(record)
        let members = try await f.library.records(includingDeleted: true)
        _ = try await f.access.beginFileLifecycle(action: .purge, entryID: entry.id,
            rootPath: f.libraryRoot.path, relativePath: entry.relativePath, members: members)
        try FileManager.default.removeItem(at: f.libraryRoot.appendingPathComponent(record.relativePath))
        // Simulate an unrelated lost/corrupt index, not a library purge commit.
        var state = try PersonalLibraryTrashStore.read(root: f.libraryRoot); state.entries = []
        try PersonalLibraryTrashStore.write(state, root: f.libraryRoot)
        await #expect(throws: PersonalFileAssistantLifecycleError.self) { try await f.lifecycle().reconcile() }
        #expect(f.conversations.contains(assistant))
        #expect(f.purged.isEmpty)
        #expect(try await f.access.pendingFileLifecycles().count == 1)
    }

    @Test func expectedConversationCASCannotRemoveAReplacement() async throws {
        let f = try Fixture(); defer { f.clean() }
        let record = try await f.create(), old = try await f.bind(record), replacement = UUID()
        try await f.access.bindAssistant(conversationID: replacement, projectID: record.id)
        #expect(try await !f.access.removeAssistant(projectID: record.id, expectedConversationID: old))
        #expect(try await f.access.assistant(projectID: record.id) == replacement)
        await #expect(throws: PersonalFileAssistantLifecycleError.self) {
            try await f.access.finishPurgedAssistant(.init(projectID: record.id, conversationID: old))
        }
        #expect(try await f.access.canAccess(conversationID: replacement, projectID: record.id, editing: true))
    }

    @Test func folderRestoreKeepsIndependentlyDeletedChildAndItsAssistantHidden() async throws {
        let f = try Fixture(); defer { f.clean() }
        try await f.library.createFolder("A", in: [])
        let child = try await f.create("Separate", folders: ["A"]), live = try await f.create("Live", folders: ["A"])
        let childAssistant = try await f.bind(child), liveAssistant = try await f.bind(live)
        _ = try await f.trash(child); f.stopped = []
        let folder = try #require(try await f.library.folderSnapshots(in: []).first)
        let event = try await f.lifecycle().perform(action: .trash, entryID: UUID(), relativePath: "A", members: [live]) {
            try await f.library.softDeleteFolder(folder, expectedProjectIDs: [child.id, live.id], eventID: $0)
        }
        #expect(f.stopped == [.init(projectID: live.id, conversationID: liveAssistant)])
        try await f.lifecycle().perform(action: .restore, entryID: event.id, relativePath: "A", members: [live]) {
            try await f.library.restore($0)
        }
        #expect(try await f.library.records().map(\.id) == [live.id])
        #expect(try await f.access.assistant(projectID: child.id) == childAssistant)
        #expect(try await f.access.assistant(projectID: live.id) == liveAssistant)
    }

    #if canImport(UIKit)
    private actor LaunchGate {
        private var entered = false
        private var entry: CheckedContinuation<Void, Never>?
        private var parked: CheckedContinuation<Void, Never>?
        func hook() async {
            entered = true; entry?.resume(); entry = nil
            await withCheckedContinuation { parked = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entry = $0 }
        }
        func open() { parked?.resume(); parked = nil }
    }

    @Test func inFlightLaunchTimeoutIsNotAStopProofAndKeepsOriginal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.studioCoordinator = StudioCoordinator(environment: environment, authority: f.access, library: f.library)
        let record = try await f.create(), assistant = try await f.bind(record), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: assistant, title: "fixture", createdAt: now, updatedAt: now))
        let center = environment.conversationCenter, gate = LaunchGate()
        center.fileAssistantStopTimeout = .zero
        center.launchTestHooks.beforeCapture = { await gate.hook() }
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "fixture", displayName: "Fixture",
            limits: .init(contextTokens: 4096, maxOutputTokens: 512), capabilities: [.text, .tools])
        let send = Task {
            try await center.startRun(goal: "synthetic pending launch", in: assistant,
                provider: provider, model: model, startOrigin: .explicitUserAction)
        }
        await gate.waitUntilEntered()
        await #expect(throws: PersonalFileAssistantLifecycleError.self) {
            _ = try await PersonalLibraryFileActions.delete(record, environment: environment, library: f.library)
        }
        #expect(try await f.library.resolve(record.id).record.id == record.id)
        #expect(try await environment.conversationStore.conversation(id: assistant) != nil)
        #expect(try await f.access.pendingFileLifecycles().isEmpty)
        await gate.open()
        await #expect(throws: Error.self) { _ = try await send.value }
        center.launchTestHooks.beforeCapture = nil
        center.fileAssistantStopTimeout = .seconds(1)
        _ = try await PersonalLibraryFileActions.delete(record, environment: environment, library: f.library)
        #expect(try await f.library.records().isEmpty)
    }

    @Test func nativeBatchPreservesBusyEditorConversationAndUnrelatedReferenceTask() async throws {
        let f = try Fixture(); defer { f.clean() }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.studioCoordinator = StudioCoordinator(environment: environment, authority: f.access, library: f.library)
        let free = try await f.create("Free"), busy = try await f.create("Visible editor")
        let freeAssistant = try await f.bind(free), busyAssistant = try await f.bind(busy), ordinary = UUID(), now = Date()
        for id in [freeAssistant, busyAssistant, ordinary] {
            try await environment.conversationStore.saveConversation(.init(id: id, title: "fixture", createdAt: now, updatedAt: now))
        }
        try await f.access.finishCreation(conversationID: ordinary, projectID: free.id)
        let lease = try PersonalLibraryFileActions.acquireUse(id: busy.id,
            directory: try await f.library.resolve(busy.id).url, libraryRoot: f.libraryRoot)
        defer { lease.release() }
        let result = await PersonalLibraryFileActions.deleteBatch([.work(free), .work(busy)], environment: environment, library: f.library)
        #expect(result.deleted.map(\.id) == [PersonalLibrarySelectionItem.work(free).id])
        #expect(result.failed.map(\.item.id) == [PersonalLibrarySelectionItem.work(busy).id])
        #expect(try await f.library.records().map(\.id) == [busy.id])
        #expect(try await environment.conversationStore.conversation(id: busyAssistant) != nil)
        #expect(try await environment.conversationStore.conversation(id: ordinary) != nil)
        #expect(environment.conversationCenter.conversations.contains { $0.id == busyAssistant })
    }

    @Test func nativeFileActionsHideRestoreAndPurgeTheActualConversation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.studioCoordinator = StudioCoordinator(environment: environment, authority: f.access, library: f.library)
        let record = try await f.create(), assistant = try await f.bind(record)
        let ordinary = UUID(), runID = UUID(), orphanRunID = UUID(), now = Date()
        for id in [assistant, ordinary] {
            try await environment.conversationStore.saveConversation(.init(id: id, title: "fixture", createdAt: now, updatedAt: now))
        }
        try await environment.runStore.saveRun(.init(id: runID, conversationID: assistant,
            state: "failed", goal: "old stopped work", startedAt: now, endedAt: now))
        try await environment.runStore.saveRun(.init(id: orphanRunID, conversationID: assistant,
            state: "preparing", goal: "process-lost owned work", startedAt: now))
        let center = environment.conversationCenter
        let entry = try await PersonalLibraryFileActions.delete(record, environment: environment, library: f.library)
        #expect(!center.conversations.contains { $0.id == assistant })
        #expect(!center.fileAssistantConversations.contains { $0.id == assistant })
        #expect(try await environment.conversationStore.conversation(id: assistant) != nil)
        try await PersonalLibraryFileActions.restore(entry, environment: environment, library: f.library)
        #expect(center.fileAssistantConversations.contains { $0.id == assistant })
        #expect(try await environment.runStore.run(id: runID)?.state == "cancelled")
        #expect(try await environment.runStore.run(id: orphanRunID)?.state == "cancelled")
        #expect(!center.hasLiveOwner(runID: runID))
        let entry2 = try await PersonalLibraryFileActions.delete(record, environment: environment, library: f.library)
        let plan = try #require(try await PersonalLibraryFileActions.permanentDeletionPlans([entry2], environment: environment, library: f.library).first)
        _ = try await PersonalLibraryFileActions.permanentlyDelete(plan, environment: environment, library: f.library)
        #expect(try await environment.conversationStore.conversation(id: assistant) == nil)
        #expect(try await environment.conversationStore.conversation(id: ordinary) != nil)
        #expect(try await f.access.assistant(projectID: record.id) == nil)
    }
    #endif
}
