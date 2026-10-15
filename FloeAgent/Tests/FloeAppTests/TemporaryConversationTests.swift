// FloeAppTests — Temporary chat orchestration through the real
// ConversationCenter with an in-memory database: nothing durable during the
// ephemeral phase, atomic/idempotent promotion, discard cancellation, and
// draft suppression. Canary strings prove no SQLite/FTS/draft leak.

import Foundation
import Testing
import UIKit
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
@testable import FloeApp

@Suite("FloeApp.TemporaryConversation")
@MainActor
struct TemporaryConversationTests {
    private final class Fixture: @unchecked Sendable {
        let environment: AppEnvironment
        let center: ConversationCenter

        @MainActor
        init() throws {
            environment = AppEnvironment.preview()
            center = ConversationCenter(environment: environment)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture()
        // The preview environment is un-migrated (bootstrap runs the real
        // migration); the schema must exist before any store write.
        try await fixture.environment.database.migrate()
        return fixture
    }

    // MARK: - DB canary helpers

    private func durableContentCounts(
        _ fixture: Fixture,
        conversationID: UUID
    ) async throws -> (conversations: Int, messages: Int, runs: Int, events: Int, inputs: Int) {
        try await fixture.environment.database.reader { db in
            let conversations = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            let messages = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            let runs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            let events = try Int.fetchOne(
                db, sql: """
                    SELECT COUNT(*) FROM run_events WHERE run_id IN (
                        SELECT id FROM runs WHERE conversation_id = ?)
                    """, arguments: [conversationID.uuidString]) ?? 0
            let inputs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pending_user_inputs WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            return (conversations, messages, runs, events, inputs)
        }
    }

    private func durableCanaryCount(_ fixture: Fixture, canary: String) async throws -> Int {
        try await fixture.environment.database.reader { db in
            let like = "%\(canary)%"
            let messages = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messages WHERE content LIKE ?",
                arguments: [like]) ?? 0
            let runs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM runs WHERE goal LIKE ?",
                arguments: [like]) ?? 0
            let events = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM run_events WHERE payload_json LIKE ?",
                arguments: [like]) ?? 0
            let inputs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pending_user_inputs WHERE content LIKE ?",
                arguments: [like]) ?? 0
            let drafts = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_parts WHERE text LIKE ?",
                arguments: [like]) ?? 0
            return messages + runs + events + inputs + drafts
        }
    }

    /// Durable credential-vault metadata rows (the secret body lives in the
    /// Keychain; `capture` writes both, so a row count is the durable proof).
    private func credentialRecordCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.environment.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credential_records") ?? 0
        }
    }

    /// Metadata rows captured specifically from model tool-call arguments.
    private func modelToolCallCredentialCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.environment.database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM credential_records WHERE origin LIKE 'model-tool-call:%'"
            ) ?? 0
        }
    }

    /// Bounded, deterministic wait for a concurrently-mutating condition.
    private func pollUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Toggle behavior

    @Test("Toggle on an empty conversation converts it in place; toggle off restores the blank ordinary row")
    func emptyToggleRoundTrip() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)

        let on = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        #expect(on == .temporaryActive(ordinary.id))
        #expect(fixture.center.isTemporaryConversation(ordinary.id))
        // The durable row is gone while temporary.
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) == nil)
        #expect(fixture.center.conversations.contains { $0.id == ordinary.id } == false)
        // The session still serves reads.
        #expect(try await fixture.center.conversationStore(for: ordinary.id).conversation(id: ordinary.id) != nil)

        let off = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        #expect(off == .restoredOrdinary(ordinary.id))
        #expect(!fixture.center.isTemporaryConversation(ordinary.id))
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
    }

    @Test("Toggle on a populated conversation starts a separate session and never touches saved history")
    func populatedToggleStartsSeparateSession() async throws {
        let fixture = try await makeFixture()
        let saved = try await fixture.center.createConversation(title: "Saved")
        try await fixture.environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: saved.id, role: "user",
            content: "saved-canary", createdAt: Date()
        ))
        let outcome = try await fixture.center.toggleTemporaryChat(for: saved.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != saved.id)
        #expect(fixture.center.isTemporaryConversation(tempID))
        #expect(!fixture.center.isTemporaryConversation(saved.id))
        // Saved history untouched and still durable.
        #expect(try await fixture.environment.conversationStore.messages(conversationID: saved.id).count == 1)
        // The temporary session is empty and not in the saved list.
        #expect(try await fixture.center.conversationStore(for: tempID).messages(conversationID: tempID).isEmpty)
        #expect(fixture.center.conversations.contains { $0.id == tempID } == false)
        // Durable DB has no trace of the temp id.
        let counts = try await durableContentCounts(fixture, conversationID: tempID)
        #expect(counts == (0, 0, 0, 0, 0))
    }

    @Test("Toggling off after ephemeral messages is not silent")
    func toggleOffWithMessagesRequiresExplicitAction() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: "ephemeral", createdAt: Date()
        ))
        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        #expect(outcome == .requiresExplicitAction(ordinary.id))
        #expect(fixture.center.isTemporaryConversation(ordinary.id))
        // Still nothing durable.
        #expect(try await durableCanaryCount(fixture, canary: "ephemeral") == 0)
    }

    // MARK: - Ephemeral phase writes nothing durable

    @Test("Session content stays out of SQLite entirely")
    func ephemeralContentNeverReachesDurableStores() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "tcanary-\(UUID().uuidString.prefix(8))"
        let (provider, model) = try await makeProviderModel(fixture)

        // Simulate a full launch + stream through the session stores.
        let launch = try await session.launchStore.prepare(RunLaunchRequest(
            conversationID: ordinary.id,
            conversationTitle: "",
            goal: canary,
            providerID: provider.id,
            modelID: model.id
        ))
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "assistant",
            content: "assistant-\(canary)", createdAt: Date().addingTimeInterval(1),
            runID: launch.run.id
        ))
        _ = try await session.runStore.appendEvent(
            runID: launch.run.id, kind: .assistantText,
            payloadJSON: #"{"delta":"\#(canary)"}"#
        )
        _ = try await session.runningInputStore.enqueue(PendingUserInput(
            conversationID: ordinary.id, content: "queued-\(canary)"
        ))

        // Everything reads back through the routed session stores.
        #expect(try await fixture.center.conversationStore(for: ordinary.id)
            .messages(conversationID: ordinary.id).count == 2)
        #expect(try await fixture.center.runStore(for: ordinary.id)
            .events(runID: launch.run.id).count >= 2)
        let initialStatus = try await session.runStore.events(runID: launch.run.id).first
        #expect(initialStatus?.kind == .status)
        #expect(initialStatus?.payloadJSON == #"{"state":"preparing"}"#)
        // And nothing durable: rows, goals, events or queued inputs.
        let counts = try await durableContentCounts(fixture, conversationID: ordinary.id)
        #expect(counts == (0, 0, 0, 0, 0))
        #expect(try await durableCanaryCount(fixture, canary: canary) == 0)
    }

    @Test("Explicit end discards RAM content, cancels owned runs and restores the converted blank row")
    func endDiscardsWithoutDurableWrites() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: "discard-canary", createdAt: Date()
        ))
        await fixture.center.endTemporaryChat()
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(ordinary.id))
        // Converted empty ordinary row restored.
        let restored = try await fixture.environment.conversationStore.conversation(id: ordinary.id)
        #expect(restored != nil)
        #expect(try await durableCanaryCount(fixture, canary: "discard-canary") == 0)
    }

    @Test("Temporary conversations cannot be exported or compacted")
    func exportAndCompactionRejected() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        await #expect(throws: FloeError.self) {
            _ = try await fixture.center.exportStructuredConversation(conversationID: ordinary.id)
        }
        await #expect(throws: FloeError.self) {
            _ = try await fixture.center.requestManualCompaction(conversationID: ordinary.id, modelID: nil)
        }
    }

    // MARK: - Promotion

    @Test("Keep persists messages, runs and events exactly once and reopens as an ordinary chat")
    func promotionPersistsCompleteHistory() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "pcanary-\(UUID().uuidString.prefix(8))"
        let (provider, model) = try await makeProviderModel(fixture)
        let launch = try await session.launchStore.prepare(RunLaunchRequest(
            conversationID: ordinary.id,
            conversationTitle: "", goal: canary, providerID: provider.id, modelID: model.id
        ))
        for index in 0..<6 {
            try await session.conversationStore.appendMessage(PersistedMessage(
                id: UUID(), conversationID: ordinary.id,
                role: index % 2 == 0 ? "user" : "assistant",
                content: "\(canary)-m\(index)",
                createdAt: Date().addingTimeInterval(TimeInterval(index)),
                runID: launch.run.id
            ))
            _ = try await session.runStore.appendEvent(
                runID: launch.run.id, kind: .assistantText,
                payloadJSON: #"{"delta":"\#(index)"}"#
            )
        }

        let saved = try await fixture.center.keepTemporaryChat()
        #expect(saved.id == ordinary.id)
        #expect(saved.purpose == .ordinary)
        #expect(saved.title.contains(canary))
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(ordinary.id))

        // Durable view is complete and ordered.
        let messages = try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id)
        #expect(messages.count == 7) // launch user message + 6 stream turns
        #expect(messages.first?.content == canary)
        #expect(messages.last?.content == "\(canary)-m5")
        let events = try await fixture.environment.runStore.events(runID: launch.run.id)
        #expect(events.map(\.sequence) == Array(1...events.count))
        // Reopened through the ordinary routing.
        let reopened = try await fixture.center.conversationStore(for: ordinary.id)
            .conversation(id: ordinary.id)
        #expect(reopened?.purpose == .ordinary)
        // Discoverable through the real sidebar ownership projection, not
        // merely present in the center's unfiltered conversation array.
        #expect(fixture.center.conversations.contains { $0.id == ordinary.id })
        let workspaceID = try #require(fixture.environment.workspaceCenter.workspaceID(for: ordinary.id))
        #expect(fixture.environment.workspaceCenter.workspaces.contains {
            $0.id == workspaceID && $0.kind == .privateTask
        })
        let ownershipCount = try await fixture.environment.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_workspace_ownership WHERE conversation_id = ?",
                             arguments: [ordinary.id.uuidString]) ?? 0
        }
        #expect(ownershipCount == 1)

        // Repeat keep is idempotent: same record, no duplicates.
        // (Session is cleared, so a repeat surfaces the durable record path.)
        let again = try await fixture.center.keepTemporaryChat()
        #expect(again.id == saved.id)
        #expect(try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id).count == 7)
    }

    @Test("Keep creates history ownership atomically; workspace failure remains temporary and retryable")
    func promotionHistoryOwnershipIsAtomic() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: "")
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: "synthetic-history-ownership", createdAt: Date()))
        let workspaces = SQLiteWorkspaceStore(database: fixture.environment.database)
        #expect(try await workspaces.workspaceID(conversationID: ordinary.id) == nil)
        try await fixture.environment.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER reject_test_workspace BEFORE INSERT ON workspaces BEGIN SELECT RAISE(ABORT, 'synthetic workspace failure'); END")
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.center.keepTemporaryChat()
        }
        #expect(fixture.center.temporarySession?.conversation.id == ordinary.id)
        #expect(try await workspaces.workspaceID(conversationID: ordinary.id) == nil)
        #expect(try await fixture.environment.conversationStore.messages(conversationID: ordinary.id).isEmpty)
        try await fixture.environment.database.writer { db in
            try db.execute(sql: "DROP TRIGGER reject_test_workspace")
        }
        _ = try await fixture.center.keepTemporaryChat()
        let keptWorkspace = try #require(try await workspaces.workspaceID(conversationID: ordinary.id))
        #expect(fixture.environment.workspaceCenter.workspaceID(for: ordinary.id) == keptWorkspace)
        #expect(try await fixture.environment.conversationStore.messages(conversationID: ordinary.id).count == 1)
        _ = try await fixture.center.keepTemporaryChat()
        #expect(try await workspaces.workspaceID(conversationID: ordinary.id) == keptWorkspace)
    }

    @Test("Keep during a live stream drains concurrent appends exactly once")
    func promotionDrainsConcurrentAppends() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: "base", createdAt: Date()
        ))
        // Appends keep landing while the promotion transaction runs.
        let appends = Task {
            for index in 0..<20 {
                try? await session.conversationStore.appendMessage(PersistedMessage(
                    id: UUID(), conversationID: ordinary.id, role: "assistant",
                    content: "late-\(index)",
                    createdAt: Date().addingTimeInterval(TimeInterval(index + 1))
                ))
            }
        }
        let promoter = ConversationPromoter(database: fixture.environment.database)
        let writer: ConversationCenter.PromotionSnapshotWriter = { saved, snapshot, runs, _ in
            // Small delay so late appends interleave with the durable write.
            try? await Task.sleep(for: .milliseconds(60))
            try await promoter.promote(ConversationPromoter.Snapshot(
                conversation: saved,
                messages: snapshot.messages,
                attachments: snapshot.attachments,
                runs: runs.runs,
                events: runs.runs.flatMap { runs.events[$0.id, default: []] },
                usage: runs.runs.flatMap { runs.usage[$0.id, default: []] },
                errors: runs.runs.flatMap { runs.errors[$0.id, default: []] }
            ))
        }
        let saved = try await fixture.center.keepTemporaryChat(snapshotWriter: writer)
        await appends.value
        // Buffered-during-promotion rows forward through the gateway.
        _ = saved
        let messages = try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id)
        #expect(messages.count == 21)
        #expect(Set(messages.map(\.content)).count == 21)
        #expect(messages.contains { $0.content == "late-19" })
        #expect(try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id)
            .filter { $0.content.hasPrefix("late-") }.count == 20)
    }

    @Test("A failed promotion transaction rolls back to zero rows, keeps RAM intact and retries cleanly")
    func failedPromotionRecoversAndRetries() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "fcanary-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: canary, createdAt: Date()
        ))

        // Route through the REAL promoter but corrupt one row so the single
        // GRDB transaction must roll back: a message owned by a conversation
        // that is not part of the snapshot violates the messages FK.
        let promoter = ConversationPromoter(database: fixture.environment.database)
        let failingWriter: ConversationCenter.PromotionSnapshotWriter = { saved, snapshot, runs, _ in
            var brokenMessages = snapshot.messages
            brokenMessages.append(PersistedMessage(
                id: UUID(), conversationID: UUID(), role: "user",
                content: "fk-breaker", createdAt: Date()
            ))
            try await promoter.promote(ConversationPromoter.Snapshot(
                conversation: saved,
                messages: brokenMessages,
                attachments: snapshot.attachments,
                runs: runs.runs,
                events: runs.runs.flatMap { runs.events[$0.id, default: []] },
                usage: runs.runs.flatMap { runs.usage[$0.id, default: []] },
                errors: runs.runs.flatMap { runs.errors[$0.id, default: []] }
            ))
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.center.keepTemporaryChat(snapshotWriter: failingWriter)
        }
        // Real rollback: no partial durable rows of any kind.
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) == nil)
        #expect(try await durableCanaryCount(fixture, canary: canary) == 0)
        #expect(try await durableCanaryCount(fixture, canary: "fk-breaker") == 0)
        // RAM session intact and promotion idle again.
        let recovered = try #require(fixture.center.temporarySession)
        #expect(recovered.promotion == .idle)
        let ramMessages = try await recovered.conversationStore.messages(conversationID: ordinary.id)
        #expect(ramMessages.map(\.content) == [canary])

        // Retry succeeds through the real transactional writer.
        let saved = try await fixture.center.keepTemporaryChat()
        #expect(saved.purpose == .ordinary)
        #expect(try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id).map(\.content) == [canary])
    }

    @Test("A second keep while one is in flight never starts a second writer")
    func concurrentKeepIsRejected() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let slowWriter: ConversationCenter.PromotionSnapshotWriter = { saved, snapshot, _, _ in
            try? await Task.sleep(for: .milliseconds(150))
            try await fixture.environment.conversationStore.saveConversation(saved)
            for message in snapshot.messages {
                try await fixture.environment.conversationStore.appendMessage(message)
            }
        }
        let first = Task {
            try await fixture.center.keepTemporaryChat(snapshotWriter: slowWriter)
        }
        try? await Task.sleep(for: .milliseconds(20))
        // Second call observes .inFlight and must not double-write.
        await #expect(throws: FloeError.self) {
            _ = try await fixture.center.keepTemporaryChat(snapshotWriter: slowWriter)
        }
        _ = try await first.value
        #expect(fixture.center.temporarySession == nil)
    }

    // MARK: - Draft suppression

    @Test("Temporary drafts stay in RAM: no durable draft before, during, or after a late flush")
    func temporaryDraftsNeverPersist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-temp-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: fileURL)
        let id = UUID()
        let canary = "draft-canary-\(UUID().uuidString.prefix(8))"

        store.setTemporaryDraftExcluded(id, true)
        _ = store.save(text: canary, conversationID: id)
        store.flush()
        let data = FileManager.default.fileExists(atPath: fileURL.path)
            ? try Data(contentsOf: fileURL) : Data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(canary))
        #expect(store.entry(for: id)?.text == canary)

        // Late lifecycle flush after unexcluding still cannot write the
        // dropped ephemeral entry.
        store.setTemporaryDraftExcluded(id, false)
        store.flush()
        let afterData = FileManager.default.fileExists(atPath: fileURL.path)
            ? try Data(contentsOf: fileURL) : Data()
        let after = String(decoding: afterData, as: UTF8.self)
        #expect(!after.contains(canary))
        #expect(store.entry(for: id) == nil)
    }

    @Test("Toggling on clears a pre-existing durable draft for the same empty conversation")
    func toggleOnClearsSameIDDraft() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let canary = "old-draft-\(UUID().uuidString.prefix(8))"
        ComposerDraftStore.shared.save(text: canary, conversationID: ordinary.id)
        defer {
            ComposerDraftStore.shared.clear(conversationID: ordinary.id)
        }
        #expect(ComposerDraftStore.shared.text(for: ordinary.id) == canary)

        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        // The durable draft is dropped; the RAM handoff bucket is empty too.
        #expect(ComposerDraftStore.shared.text(for: ordinary.id).isEmpty)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        #expect(ComposerDraftStore.shared.text(for: ordinary.id).isEmpty)
    }

    // MARK: - Direct (launchpad) session start

    @Test("startTemporarySession hosts a RAM-only conversation with the carried draft; nothing durable is created")
    func startTemporarySessionIsMemoryOnly() async throws {
        let fixture = try await makeFixture()
        let canary = "  launch-\(UUID().uuidString.prefix(8)) padded  "
        let modelID = UUID()
        let id = try await fixture.center.startTemporarySession(
            initialDraft: canary,
            preferredModelID: modelID
        )
        #expect(fixture.center.isTemporaryConversation(id))
        let session = try #require(fixture.center.temporarySession)
        #expect(session.conversation.purpose == .temporary)
        #expect(session.convertedEmptyOrdinaryID == nil)
        #expect(session.sourceConversationID == nil)
        #expect(session.preferredModelID == modelID)
        // Draft lives in the RAM-only bucket, VERBATIM (whitespace kept).
        #expect(ComposerDraftStore.shared.text(for: id) == canary)
        defer {
            ComposerDraftStore.shared.clear(conversationID: id)
        }
        // Nothing durable: no conversation row, no message, no draft file.
        let counts = try await durableContentCounts(fixture, conversationID: id)
        #expect(counts == (0, 0, 0, 0, 0))
        #expect(try await durableCanaryCount(fixture, canary: canary) == 0)
        // Refuses a second concurrent session.
        await #expect(throws: FloeError.self) {
            _ = try await fixture.center.startTemporarySession(initialDraft: "x")
        }
    }

    @Test("Temporary sends keep tools enabled through the read-only ceiling; ordinary mode selection is untouched")
    func temporaryEffectiveModeKeepsToolsEnabled() async throws {
        let fixture = try await makeFixture()
        // A launchpad-direct temporary session (the only UI entry).
        let id = try await fixture.center.startTemporarySession(initialDraft: "mode check")
        defer { ComposerDraftStore.shared.clear(conversationID: id) }
        let model = ThreadDetailViewModel(conversationID: id, center: fixture.center)
        #expect(model.isTemporary)
        // The forced chat-only mode is gone: the temporary run must reach the
        // request pipeline with tools ENABLED so ConversationCenter's
        // immutable read-only ceiling (TemporaryChatToolPolicy) is the
        // authority that narrows the catalog. `.chat` would disable tools
        // entirely and bypass that audited policy.
        #expect(model.effectiveAgentMode == .agent)
        #expect(model.effectiveAgentMode.toolsEnabled)
        // Plan/goal (durable-record modes) can never be sent from a temporary
        // view model, even if the stored selection is stale.
        model.agentMode = .plan
        #expect(model.effectiveAgentMode == .agent)
        model.agentMode = .goal
        #expect(model.effectiveAgentMode == .agent)
        // Ordinary conversations keep the user's own selection exactly.
        let ordinary = try await fixture.center.createConversation(title: nil)
        let ordinaryModel = ThreadDetailViewModel(conversationID: ordinary.id, center: fixture.center)
        ordinaryModel.selectAgentMode(.chat)
        #expect(ordinaryModel.effectiveAgentMode == .chat)
        ordinaryModel.selectAgentMode(.plan)
        #expect(ordinaryModel.effectiveAgentMode == .plan)
    }

    @Test("Ending a launchpad-direct session discards everything and lands on newTask with no restored row")
    func directSessionEndLandsOnNewTask() async throws {
        let fixture = try await makeFixture()
        let id = try await fixture.center.startTemporarySession(initialDraft: "draft text")
        let session = try #require(fixture.center.temporarySession)
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "user",
            content: "ephemeral-direct", createdAt: Date()
        ))
        let target = await fixture.center.endTemporaryChat()
        #expect(target == .newTask)
        #expect(fixture.center.temporarySession == nil)
        #expect(try await fixture.environment.conversationStore.conversation(id: id) == nil)
        #expect(try await durableCanaryCount(fixture, canary: "ephemeral-direct") == 0)
        #expect(ComposerDraftStore.shared.text(for: id).isEmpty)
    }

    @Test("Ending an in-place converted session restores the blank ordinary row; a separate session returns to its source")
    func endTargetsMatchHowTheSessionStarted() async throws {
        let fixture = try await makeFixture()
        // In-place conversion.
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        #expect(await fixture.center.endTemporaryChat() == .conversation(ordinary.id))
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        // Separate session from a populated saved chat.
        let saved = try await fixture.center.createConversation(title: "Saved")
        try await fixture.environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: saved.id, role: "user",
            content: "kept", createdAt: Date()
        ))
        _ = try await fixture.center.toggleTemporaryChat(for: saved.id)
        #expect(await fixture.center.endTemporaryChat() == .conversation(saved.id))
        #expect(try await fixture.environment.conversationStore.messages(conversationID: saved.id).count == 1)
    }

    // MARK: - Launch races (F1), leave semantics and retention

    /// Deterministic gate for the center's launch-test hooks: the hook
    /// signals `entered` before parking on `wait()` until `open()`.
    /// An actor keeps the continuation bookkeeping Swift-6 async-safe.
    private actor LaunchGate {
        private var didEnter = false
        private var isOpen = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var parked: CheckedContinuation<Void, Never>?

        func hook() async {
            didEnter = true
            let waiters = enteredWaiters
            enteredWaiters = []
            waiters.forEach { $0.resume() }
            if isOpen { return }
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    parked = continuation
                }
            }
        }

        func waitUntilEntered() async {
            if didEnter { return }
            await withCheckedContinuation { continuation in
                if didEnter {
                    continuation.resume()
                } else {
                    enteredWaiters.append(continuation)
                }
            }
        }

        func open() {
            isOpen = true
            let continuation = parked
            parked = nil
            continuation?.resume()
        }
    }

    private func makeProviderModel(_ fixture: Fixture) async throws -> (ProviderProfile, ModelProfile) {
        let configuration = ModelConfigurationStore(database: fixture.environment.database)
        let provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.com/v1")!
        )
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "test-model",
            displayName: "Test", limits: .init(contextTokens: 4096, maxOutputTokens: 1024),
            capabilities: [.text, .tools]
        )
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        var preferences = try await configuration.preferences()
        preferences.defaultAgentModelID = model.id
        try await configuration.savePreferences(preferences)
        await fixture.center.reload()
        // Hermetic default: a run that actually reaches the provider stage
        // fails immediately and deterministically — never a real network
        // request. Tests that need a scripted provider replace the override.
        fixture.center.providerAdapterTestOverride = { _, _ in FailingProviderAdapter() }
        return (provider, model)
    }

    @Test("End while a send is still before secret capture/launch prepare destroys the session and the launch fails closed (F1)")
    func endRacingPreDeferredLaunchFailsClosed() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let saved = try await fixture.center.createConversation(title: "Saved")
        try await fixture.environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: saved.id, role: "user",
            content: "anchor", createdAt: Date()
        ))
        _ = try await fixture.center.toggleTemporaryChat(for: saved.id)
        let tempID = try #require(fixture.center.temporarySession?.conversation.id)

        let gate = LaunchGate()
        fixture.center.launchTestHooks.beforeCapture = { await gate.hook() }
        let send = Task {
            try await fixture.center.startRun(
                goal: "race-canary-\(UUID().uuidString.prefix(8))",
                in: tempID,
                provider: provider,
                model: model,
                startOrigin: .explicitUserAction
            )
        }
        await gate.waitUntilEntered()
        // Actual leave destroys immediately, even though the launch is
        // parked before its first store effect.
        let target = await fixture.center.endTemporaryChat()
        #expect(target == .conversation(saved.id))
        await gate.open()

        await #expect(throws: (any Error).self) {
            _ = try await send.value
        }
        // Nothing durable for the temporary id, and the saved chat intact.
        let counts = try await durableContentCounts(fixture, conversationID: tempID)
        #expect(counts == (0, 0, 0, 0, 0))
        #expect(try await fixture.environment.conversationStore.messages(conversationID: saved.id).count == 1)
        // A brand-new ordinary conversation is unaffected by the late launch.
        let fresh = try await fixture.center.createConversation(title: nil)
        #expect(fixture.center.temporarySession == nil)
        _ = fresh
    }

    @Test("End while the deferred run is registered dispatches cancellation, destroys the session and drops every late callback")
    func endRacingRegisteredRunDestroysImmediately() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let session = try #require(fixture.center.temporarySession)

        let gate = LaunchGate()
        fixture.center.launchTestHooks.deferredTaskBody = { await gate.hook() }
        let send = Task {
            try await fixture.center.startRun(
                goal: "running-canary-\(UUID().uuidString.prefix(8))",
                in: id,
                provider: provider,
                model: model,
                startOrigin: .explicitUserAction
            )
        }
        // The launch registers the run and returns immediately; the owner
        // task parks on the hook before reaching the provider.
        let started = try await send.value
        let runID = started.runID
        #expect(fixture.center.hasLiveOwner(runID: runID))

        let target = await fixture.center.endTemporaryChat()
        #expect(target == .newTask)
        // Immediate destroy: no live owner, no session, nothing durable.
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.hasLiveOwner(runID: runID))
        let counts = try await durableContentCounts(fixture, conversationID: id)
        #expect(counts == (0, 0, 0, 0, 0))

        // Late callbacks after the destroy are dropped without resurrecting
        // anything: the parked task resumes into the tombstone.
        await gate.open()
        let outcome = await started.result.value
        switch outcome {
        case .success:
            Issue.record("The destroyed temporary run must not complete successfully")
        case .failure:
            break
        }
        let after = try await durableContentCounts(fixture, conversationID: id)
        #expect(after == (0, 0, 0, 0, 0))
        _ = session
    }

    @Test("A late End callback bound to an old session cannot destroy a replacement session")
    func staleEndCallbackCannotDestroyNewSession() async throws {
        let fixture = try await makeFixture()
        let firstID = try await fixture.center.startTemporarySession(initialDraft: "")
        await fixture.center.endTemporaryChat()
        #expect(fixture.center.temporarySession == nil)
        let secondID = try await fixture.center.startTemporarySession(initialDraft: "")
        #expect(secondID != firstID)
        let target = await fixture.center.endTemporaryChat(expectedConversationID: firstID)
        #expect(target == .unavailable)
        #expect(fixture.center.temporarySession?.conversation.id == secondID)
    }

    @Test("Reload/foreground reconciliation keeps the temporary session and its content (backgrounding is not a leave)")
    func backgroundAndForegroundKeepTheTemporarySession() async throws {
        let fixture = try await makeFixture()
        let id = try await fixture.center.startTemporarySession(initialDraft: "draft")
        let session = try #require(fixture.center.temporarySession)
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "user",
            content: "foreground-canary", createdAt: Date()
        ))
        // Foreground/reload reconciliation runs while the session lives.
        await fixture.center.reload()
        await fixture.center.resumeSafeRunsAfterForeground()
        #expect(fixture.center.temporarySession?.conversation.id == id)
        #expect(fixture.center.isTemporaryConversation(id))
        let messages = try await fixture.center.conversationStore(for: id)
            .messages(conversationID: id)
        #expect(messages.map(\.content) == ["foreground-canary"])
        // Availability projection still routes the id as present.
        #expect(!fixture.center.conversations.contains { $0.id == id })
    }

    @Test("Temporary ingress secrets are never captured into the credential store (F4)")
    func temporaryIngressSecretsStayOutOfTheCredentialStore() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let goal = "my api key is \"sk-test-\(UUID().uuidString.prefix(8))\""
        let scanned = SecretIngressScanner.scan(goal)
        #expect(scanned.captures.count == 1)
        let captureID = try #require(scanned.captures.first?.id)

        let gate = LaunchGate()
        fixture.center.launchTestHooks.beforeCapture = { await gate.hook() }
        let send = Task {
            try await fixture.center.startRun(
                goal: goal,
                in: id,
                provider: provider,
                model: model,
                startOrigin: .explicitUserAction
            )
        }
        await gate.waitUntilEntered()
        await gate.open()
        // Let the launch resolve (it fails at the provider stage; the
        // capture decision at the ingress boundary is what matters).
        _ = try? await send.value
        let record = try await fixture.environment.credentialStore.record(id: captureID)
        #expect(record == nil)
        await fixture.center.endTemporaryChat()
    }

    @Test("A keep racing the deferred launch promotes the buffered rows and the initiated run forwards into the saved chat (F1/F12)")
    func keepRacingDeferredLaunchAdoptsCurrentRecords() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let session = try #require(fixture.center.temporarySession)

        let gate = LaunchGate()
        fixture.center.launchTestHooks.deferredTaskBody = { await gate.hook() }
        let send = Task {
            try await fixture.center.startRun(
                goal: "keep-race-\(UUID().uuidString.prefix(8))",
                in: id,
                provider: provider,
                model: model,
                startOrigin: .explicitUserAction
            )
        }
        let started = try await send.value
        await gate.waitUntilEntered()
        // Enqueue a pending input BEFORE the promotion — it must survive.
        try await session.runningInputStore.enqueue(PendingUserInput(
            conversationID: id, content: "queued-through-keep"
        ))
        let saved = try await fixture.center.keepTemporaryChat()
        #expect(saved.id == id)
        #expect(saved.purpose == .ordinary)
        // Observe the promotion boundary while the runtime is deterministically
        // parked. After it finishes, the ordinary queue may legitimately consume
        // this follow-up; asserting it stays pending then would race real work.
        // The promoted durable view carries the queued input (F2).
        let pending = try await fixture.environment.runningInputStore
            .pending(conversationID: id)
        #expect(pending.map(\.content) == ["queued-through-keep"])
        await gate.open()
        _ = try? await started.result.value
        // This original run exists once even if a queued follow-up has already
        // started its own run. Do not mistake that authorized work for duplication.
        let messages = try await fixture.environment.conversationStore.messages(conversationID: id)
        #expect(messages.filter { $0.runID == started.runID && $0.role == "user" }.count == 1)
        // No resumable temporary state remains.
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(id))
    }

    @Test("A retry after a committed-but-throwing writer never double-inserts (F8 idempotent resume)")
    func committedThenThrowingWriterRetriesExactlyOnce() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "resume-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: canary, createdAt: Date()
        ))
        let promoter = ConversationPromoter(database: fixture.environment.database)
        final class AttemptBox: @unchecked Sendable { var count = 0 }
        let attempts = AttemptBox()
        let writer: ConversationCenter.PromotionSnapshotWriter = { saved, snapshot, runs, inputs in
            attempts.count += 1
            try await promoter.promote(ConversationPromoter.Snapshot(
                conversation: saved,
                messages: snapshot.messages,
                attachments: snapshot.attachments,
                runs: runs.runs,
                events: runs.runs.flatMap { runs.events[$0.id, default: []] },
                usage: runs.runs.flatMap { runs.usage[$0.id, default: []] },
                errors: runs.runs.flatMap { runs.errors[$0.id, default: []] },
                inputs: inputs
            ))
            if attempts.count == 1 {
                // The durable commit landed but the writer could not confirm
                // it (post-commit failure): the retry must resume, not
                // duplicate.
                throw FloeError.internalError("injected post-commit failure")
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.center.keepTemporaryChat(snapshotWriter: writer)
        }
        #expect(fixture.center.temporarySession?.promotion == .idle)
        let saved = try await fixture.center.keepTemporaryChat(snapshotWriter: writer)
        #expect(saved.purpose == .ordinary)
        #expect(attempts.count == 2)
        // Exactly-once durable rows after the resumed retry.
        let messages = try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id)
        #expect(messages.map(\.content) == [canary])
    }

    @Test("Temporary launch and queue reject attachments before any store or provider effect (F6)")
    func temporaryLaunchRejectsAttachments() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let attachment = AttachmentRef(
            id: UUID(), kind: .document, displayName: "notes.txt",
            byteCount: 4, sha256: "deadbeef", storage: .none,
            relativePath: nil, createdAt: Date()
        )
        await #expect(throws: FloeError.self) {
            _ = try await fixture.center.startRun(
                goal: "text only",
                in: id,
                provider: provider,
                model: model,
                attachments: [attachment],
                startOrigin: .explicitUserAction
            )
        }
        // A live run id is required for the queued path; fabricate one in the
        // session store to prove the queue gate fires before any write.
        let runID = UUID()
        try await fixture.center.runStore(for: id).saveRun(RunRecord(
            id: runID, conversationID: id, state: "running",
            goal: "host", startedAt: Date()
        ))
        await #expect(throws: FloeError.self) {
            try await fixture.center.submitRunningInput(
                content: "with file",
                in: id,
                expectedRunID: runID,
                mode: .queue,
                selectedModelID: nil,
                workspaceID: nil,
                executionMode: .chat,
                attachments: [attachment]
            )
        }
        // The rejected attachment never reached the queue.
        #expect(try await fixture.center.runningInputStore(for: id)
            .pending(conversationID: id).isEmpty)
        await fixture.center.endTemporaryChat()
    }

    @Test("Keep migrates the un-sent ephemeral composer draft into the durable bucket; End still drops it (F5/F9)")
    func keepMigratesDraftAndEndDropsIt() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let canary = "draft-\(UUID().uuidString.prefix(8))"
        ComposerDraftStore.shared.save(text: canary, conversationID: ordinary.id)
        defer {
            ComposerDraftStore.shared.clear(conversationID: ordinary.id)
        }
        _ = try await fixture.center.keepTemporaryChat()
        // The text survives into the durable bucket with a monotonic revision.
        let entry = try #require(ComposerDraftStore.shared.entry(for: ordinary.id))
        #expect(entry.text == canary)
        #expect(entry.revision >= 2)
        ComposerDraftStore.shared.clear(conversationID: ordinary.id)

        // End path: the ephemeral draft is dropped, never migrated.
        let other = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: other.id)
        ComposerDraftStore.shared.save(text: "dropped-\(UUID().uuidString.prefix(8))",
                                       conversationID: other.id)
        await fixture.center.endTemporaryChat()
        #expect(ComposerDraftStore.shared.entry(for: other.id) == nil)
    }

    @Test("Navigation during a blocked Keep destroys the session BEFORE the writer releases; a stale End callback cannot touch the new session; background preserves")
    func blockedKeepNavigationDestroysImmediately() async throws {
        let fixture = try await makeFixture()
        // In-place converted session: End must restore the blank ordinary row.
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "blocked-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: canary, createdAt: Date()
        ))
        ComposerDraftStore.shared.save(text: "draft-\(canary)", conversationID: ordinary.id)
        defer {
            ComposerDraftStore.shared.clear(conversationID: ordinary.id)
        }

        // A writer that stays blocked until the test releases it and then
        // fails: the Keep reaches NO durable commit while navigation
        // happens, so nothing uncommitted may survive the destroy.
        let gate = LaunchGate()
        let writer: ConversationCenter.PromotionSnapshotWriter = { _, _, _, _ in
            await gate.hook()
            throw FloeError.internalError("blocked writer released after the leave")
        }
        let keep = Task {
            try await fixture.center.keepTemporaryChat(snapshotWriter: writer)
        }
        await gate.waitUntilEntered()

        // Actual leave while the writer is still parked. Run the destroy in
        // its own task: its synchronous detach must land BEFORE it suspends
        // on the blocked keep settlement.
        let endTask = Task {
            await fixture.center.endTemporaryChat(expectedConversationID: ordinary.id)
        }
        // Let the destroy run up to its settlement await. The writer is still
        // blocked — proving the destruction did not wait for it.
        await Task.yield()
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(ordinary.id))
        #expect(ComposerDraftStore.shared.text(for: ordinary.id).isEmpty)

        // Release the writer: the settled keep finds closed stores and fails;
        // nothing uncommitted survives.
        await gate.open()
        await #expect(throws: (any Error).self) {
            _ = try await keep.value
        }
        let target = await endTask.value
        #expect(target == .conversation(ordinary.id))
        // Only the restored blank ordinary row exists — the blocked save
        // left nothing durable and the temp canary is gone.
        let restored = try await fixture.environment.conversationStore.conversation(id: ordinary.id)
        #expect(restored != nil)
        #expect(restored?.title == "")
        #expect(try await fixture.environment.conversationStore.messages(conversationID: ordinary.id).isEmpty)
        #expect(try await durableCanaryCount(fixture, canary: canary) == 0)

        // Old-callback safety: a new session B started afterwards is not
        // affected by a stale End bound to the destroyed identity.
        let bID = try await fixture.center.startTemporarySession(initialDraft: "")
        #expect(fixture.center.temporarySession?.conversation.id == bID)
        let stale = await fixture.center.endTemporaryChat(expectedConversationID: ordinary.id)
        #expect(stale == .unavailable)
        #expect(fixture.center.temporarySession?.conversation.id == bID)
        // Background-style reload/foreground keeps B alive.
        await fixture.center.reload()
        await fixture.center.resumeSafeRunsAfterForeground()
        #expect(fixture.center.temporarySession?.conversation.id == bID)
        await fixture.center.endTemporaryChat()
    }

    @Test("Navigation during a blocked Keep whose durable commit ALREADY landed preserves only the committed ordinary save")
    func blockedKeepAfterCommitPreservesCommittedSave() async throws {
        let fixture = try await makeFixture()
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let session = try #require(fixture.center.temporarySession)
        let canary = "committed-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "user",
            content: canary, createdAt: Date()
        ))
        // Writer: commit through the real promoter, then block. The leave
        // destroys the temporary surface (closing its RAM buffers) while the
        // writer is still parked; after release the gateway finds closed
        // stores, so the keep settles as a failure — but the committed rows
        // stay ordinary truth and no temporary surface is resurrected.
        let promoter = ConversationPromoter(database: fixture.environment.database)
        let gate = LaunchGate()
        let writer: ConversationCenter.PromotionSnapshotWriter = { saved, snapshot, runs, inputs in
            try await promoter.promote(ConversationPromoter.Snapshot(
                conversation: saved,
                messages: snapshot.messages,
                attachments: snapshot.attachments,
                runs: runs.runs,
                events: runs.runs.flatMap { runs.events[$0.id, default: []] },
                usage: runs.runs.flatMap { runs.usage[$0.id, default: []] },
                errors: runs.runs.flatMap { runs.errors[$0.id, default: []] },
                inputs: inputs
            ))
            await gate.hook()
        }
        let keep = Task {
            try await fixture.center.keepTemporaryChat(snapshotWriter: writer)
        }
        await gate.waitUntilEntered()
        let endTask = Task {
            await fixture.center.endTemporaryChat(expectedConversationID: id)
        }
        // The destroy lands while the writer is still parked.
        let destroyed = await pollUntil { await fixture.center.temporarySession == nil }
        #expect(destroyed)
        await gate.open()
        // The keep settles AFTER the destroy: its outcome (success or
        // failure) must never reactivate the destroyed session.
        _ = try? await keep.value
        _ = await endTask.value
        let saved = try await fixture.environment.conversationStore.conversation(id: id)
        #expect(saved != nil)
        #expect(saved?.purpose == .ordinary)
        let savedMessages = try await fixture.environment.conversationStore
            .messages(conversationID: id)
        #expect(savedMessages.map(\.content) == [canary])
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(id))
    }

    // MARK: - Post-commit retry (F8), credential capture (F4/B), identity binding (F1/C),
    // frozen run authority (D) and the stale-End contract (E)

    @Test("A post-commit gateway failure makes the session retryable again and the retry resumes exactly once (F8/A)")
    func postCommitGatewayFailureRetriesExactlyOnce() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "tail-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: canary, createdAt: Date()
        ))

        // Fail the RUN-store gateway step (2) after the conversation gateway
        // (1) already forwarded: the durable writer transaction has really
        // committed, so this is a genuine post-commit failure.
        fixture.center.promotionTestHooks.beforeGatewayStep = { step in
            if step == 2 {
                throw FloeError.internalError("injected post-commit gateway failure")
            }
        }
        await #expect(throws: ConversationCenter.TemporaryKeepError.self) {
            _ = try await fixture.center.keepTemporaryChat()
        }
        // The committed rows are ordinary truth...
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id).map(\.content) == [canary])
        // ...and the session is TRYABLE again (not stuck in .inFlight, which
        // used to reject every retry with "A save is already in progress").
        let recovered = try #require(fixture.center.temporarySession)
        #expect(recovered.promotion == .idle)

        // The retry resumes the failed gateway step through the pinned frozen
        // context: no double insert, no re-begin, no duplicate events.
        fixture.center.promotionTestHooks.beforeGatewayStep = nil
        let saved = try await fixture.center.keepTemporaryChat()
        #expect(saved.id == ordinary.id)
        #expect(saved.purpose == .ordinary)
        #expect(fixture.center.temporarySession == nil)
        #expect(try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id).map(\.content) == [canary])
        #expect(try await fixture.environment.runStore.runs(conversationID: ordinary.id).isEmpty)
    }

    @Test("A temporary run never captures model tool-call credentials into the vault (F4/B)")
    func temporaryToolCallArgumentsNeverReachTheCredentialVault() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let canary = "vaultcanary\(UUID().uuidString.prefix(8))"
        let before = try await credentialRecordCount(fixture)
        #expect(try await modelToolCallCredentialCount(fixture) == 0)

        let state = ScriptedToolCallProviderState()
        fixture.center.providerAdapterTestOverride = { _, _ in
            ScriptedToolCallProvider(state: state, canary: canary)
        }
        defer { fixture.center.providerAdapterTestOverride = nil }

        let started = try await fixture.center.startRun(
            goal: "hello",
            in: id,
            provider: provider,
            model: model,
            startOrigin: .explicitUserAction
        )
        // The scripted provider must actually be consumed: the sensitive
        // argument only reaches the (removed) normalizer path if the runtime
        // ingested the structured tool call.
        let consumed = await pollUntil { state.streamCount >= 1 }
        #expect(consumed)
        // Give the denial/next-turn handling a beat to finish its intake.
        _ = await pollUntil(timeout: 2) { !fixture.center.hasLiveOwner(runID: started.runID) }

        // Zero vault capture: no new credential metadata rows at all, and
        // never one with the model-tool-call origin.
        #expect(try await credentialRecordCount(fixture) == before)
        #expect(try await modelToolCallCredentialCount(fixture) == 0)
        // The synthetic secret never reached any durable content surface.
        #expect(try await durableCanaryCount(fixture, canary: canary) == 0)
        await fixture.center.endTemporaryChat()
    }

    @Test("A successfully-released blocked Keep after End cannot erase the replacement session or overwrite the committed save (F1/C+E)")
    func blockedKeepSuccessAfterEndCannotEraseReplacementSession() async throws {
        let fixture = try await makeFixture()
        // In-place converted session: End must restore the same durable id.
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let session = try #require(fixture.center.temporarySession)
        let canary = "hold-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: ordinary.id, role: "user",
            content: canary, createdAt: Date()
        ))
        ComposerDraftStore.shared.save(text: "draft-\(canary)", conversationID: ordinary.id)
        defer {
            ComposerDraftStore.shared.clear(conversationID: ordinary.id)
        }

        // Writer commits through the REAL promoter, then blocks: the leave
        // and a replacement session happen while the keep is still parked.
        let promoter = ConversationPromoter(database: fixture.environment.database)
        let gate = LaunchGate()
        let writer: ConversationCenter.PromotionSnapshotWriter = { saved, snapshot, runs, inputs in
            try await promoter.promote(ConversationPromoter.Snapshot(
                conversation: saved,
                messages: snapshot.messages,
                attachments: snapshot.attachments,
                runs: runs.runs,
                events: runs.runs.flatMap { runs.events[$0.id, default: []] },
                usage: runs.runs.flatMap { runs.usage[$0.id, default: []] },
                errors: runs.runs.flatMap { runs.errors[$0.id, default: []] },
                inputs: inputs
            ))
            await gate.hook()
        }
        let keep = Task {
            try await fixture.center.keepTemporaryChat(
                expectedConversationID: ordinary.id,
                snapshotWriter: writer)
        }
        await gate.waitUntilEntered()
        let endTask = Task {
            await fixture.center.endTemporaryChat(expectedConversationID: ordinary.id)
        }
        let destroyed = await pollUntil { await fixture.center.temporarySession == nil }
        #expect(destroyed)

        // A brand-new replacement session is allowed while A still settles.
        let replacementDraft = "replacement-draft-\(canary)"
        let bID = try await fixture.center.startTemporarySession(initialDraft: replacementDraft)
        #expect(bID != ordinary.id)
        #expect(fixture.center.temporarySession?.conversation.id == bID)

        // Release A's blocked writer with SUCCESS: the committed promotion is
        // ordinary truth, but the completion must not touch B, migrate A's
        // draft, or overwrite the just-committed record with a blank row.
        await gate.open()
        _ = try? await keep.value
        _ = await endTask.value

        #expect(fixture.center.temporarySession?.conversation.id == bID)
        #expect(fixture.center.isTemporaryConversation(bID))
        #expect(ComposerDraftStore.shared.text(for: bID) == replacementDraft)
        #expect(ComposerDraftStore.shared.text(for: ordinary.id).isEmpty)
        let saved = try await fixture.environment.conversationStore.conversation(id: ordinary.id)
        #expect(saved != nil)
        #expect(saved?.purpose == .ordinary)
        #expect(saved?.title == canary)
        #expect(try await fixture.environment.conversationStore
            .messages(conversationID: ordinary.id).map(\.content) == [canary])
        await fixture.center.endTemporaryChat(expectedConversationID: bID)
    }

    @Test("A blocked Keep that FAILS after End cannot resurrect the destroyed session or touch the replacement (F1/C)")
    func blockedKeepFailureAfterEndCannotResurrectSession() async throws {
        let fixture = try await makeFixture()
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let session = try #require(fixture.center.temporarySession)
        let canary = "resurrect-\(UUID().uuidString.prefix(8))"
        try await session.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "user",
            content: canary, createdAt: Date()
        ))

        let gate = LaunchGate()
        let writer: ConversationCenter.PromotionSnapshotWriter = { _, _, _, _ in
            await gate.hook()
            throw FloeError.internalError("blocked writer released after the leave")
        }
        let keep = Task {
            try await fixture.center.keepTemporaryChat(snapshotWriter: writer)
        }
        await gate.waitUntilEntered()
        let endTask = Task {
            await fixture.center.endTemporaryChat(expectedConversationID: id)
        }
        let destroyed = await pollUntil { await fixture.center.temporarySession == nil }
        #expect(destroyed)

        let replacementDraft = "replacement-\(canary)"
        let bID = try await fixture.center.startTemporarySession(initialDraft: replacementDraft)
        await gate.open()
        await #expect(throws: (any Error).self) {
            _ = try await keep.value
        }
        let endTarget = await endTask.value
        #expect(endTarget == .newTask)

        // No resurrection: B stays the single active session, A is gone for
        // good and wrote nothing durable.
        #expect(fixture.center.temporarySession?.conversation.id == bID)
        #expect(!fixture.center.isTemporaryConversation(id))
        #expect(ComposerDraftStore.shared.text(for: bID) == replacementDraft)
        #expect(try await fixture.environment.conversationStore.conversation(id: id) == nil)
        #expect(try await durableCanaryCount(fixture, canary: canary) == 0)
        await fixture.center.endTemporaryChat(expectedConversationID: bID)
        ComposerDraftStore.shared.clear(conversationID: bID)
    }

    @Test("A destroyed temporary run keeps its frozen store authority: late failure never falls back to durable storage (D)")
    func destroyedTemporaryRunKeepsFrozenStoreAuthority() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")

        let gate = LaunchGate()
        fixture.center.launchTestHooks.deferredTaskBody = { await gate.hook() }
        let send = Task {
            try await fixture.center.startRun(
                goal: "authority-\(UUID().uuidString.prefix(8))",
                in: id,
                provider: provider,
                model: model,
                startOrigin: .explicitUserAction
            )
        }
        let started = try await send.value
        let runID = started.runID
        #expect(fixture.center.hasLiveOwner(runID: runID))

        // Destroy the session while the run is still parked before its
        // provider stage: the frozen identity must survive the destroy.
        let endTarget = await fixture.center.endTemporaryChat()
        #expect(endTarget == .newTask)
        #expect(fixture.center.hasFrozenTemporaryRunAuthority(runID: runID, conversationID: id))
        // The terminal-failure routing resolves to the destroyed session's
        // closed buffer, never the durable environment store: a late write
        // fails closed instead of landing in ordinary storage.
        let resolved = fixture.center.runStoreForTerminalRun(runID: runID, conversationID: id)
        // The resolved authority is the session's own ephemeral store — never
        // the durable environment store. (A type-name check avoids casting a
        // non-class-bound protocol existential, which crashes Swift 6.4's
        // SILGen.)
        #expect(String(describing: type(of: resolved)).contains("EphemeralRunStore"))
        await #expect(throws: (any Error).self) {
            try await resolved.updateRunState(id: runID, state: "failed", endedAt: Date())
        }

        // Release the parked deferred task: the late launch failure runs the
        // frozen-authority path, writes nothing durable and then clears the
        // frozen identity in its own terminal cleanup.
        await gate.open()
        _ = try? await started.result.value
        #expect(!fixture.center.hasFrozenTemporaryRunAuthority(runID: runID, conversationID: id))
        #expect(try await durableContentCounts(fixture, conversationID: id) == (0, 0, 0, 0, 0))
    }

    @Test("End cancels a live temporary run through the explicit service cancel, not task cancellation alone (D)")
    func endCancelsLiveTemporaryRunService() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let state = HangingProviderState()
        fixture.center.providerAdapterTestOverride = { _, _ in
            HangingProvider(state: state)
        }
        defer { fixture.center.providerAdapterTestOverride = nil }

        let send = Task {
            try await fixture.center.startRun(
                goal: "hang-\(UUID().uuidString.prefix(8))",
                in: id,
                provider: provider,
                model: model,
                startOrigin: .explicitUserAction
            )
        }
        let started = try await send.value
        // The run reaches the provider stream and stays there.
        let streaming = await pollUntil { state.started }
        #expect(streaming)
        #expect(fixture.center.hasLiveOwner(runID: started.runID))

        let target = await fixture.center.endTemporaryChat()
        #expect(target == .newTask)
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.hasLiveOwner(runID: started.runID))
        // The provider stream of the owned service is actually terminated —
        // the explicit `ConversationRunService.cancel()` reached the runtime
        // instead of being lost with the detached `runServices` entry.
        let terminated = await pollUntil { state.terminated }
        #expect(terminated)
        #expect(try await durableContentCounts(fixture, conversationID: id) == (0, 0, 0, 0, 0))
        _ = try? await started.result.value
    }

    @Test("End bound to a destroyed identity with no active session is unavailable and never navigates (E)")
    func staleEndWithoutActiveSessionIsUnavailable() async throws {
        let fixture = try await makeFixture()
        let id = try await fixture.center.startTemporarySession(initialDraft: "")
        let firstTarget = await fixture.center.endTemporaryChat(expectedConversationID: id)
        #expect(firstTarget == .newTask)
        #expect(fixture.center.temporarySession == nil)
        // A stale callback for the same identity finds no active session and
        // must resolve to .unavailable (no navigation), never .newTask.
        let staleTarget = await fixture.center.endTemporaryChat(expectedConversationID: id)
        #expect(staleTarget == .unavailable)
        // An unscoped programmatic End still resolves to the fresh-task surface.
        let unscopedTarget = await fixture.center.endTemporaryChat()
        #expect(unscopedTarget == .newTask)
    }

    @Test("A stale End/Keep bound to a destroyed epoch cannot touch a replacement session that reuses the same UUID (epoch identity)")
    func staleEpochCallbacksCannotTouchSameIDReplacement() async throws {
        let fixture = try await makeFixture()
        // Epoch A: in-place converted temporary session at id X.
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let epochA = try #require(fixture.center.temporarySession)
        #expect(epochA.conversation.id == ordinary.id)
        let firstEnd = await fixture.center.endTemporaryChat(
            expectedConversationID: ordinary.id,
            expectedIncarnation: epochA.incarnation
        )
        #expect(firstEnd == .conversation(ordinary.id))
        // Epoch B: the converted blank row is re-hosted at the SAME UUID.
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let epochB = try #require(fixture.center.temporarySession)
        #expect(epochB.conversation.id == ordinary.id)
        #expect(epochB.incarnation != epochA.incarnation)

        // A stale End bound to epoch A must not destroy epoch B — the UUID
        // alone would have matched.
        let staleEnd = await fixture.center.endTemporaryChat(
            expectedConversationID: ordinary.id,
            expectedIncarnation: epochA.incarnation
        )
        #expect(staleEnd == .unavailable)
        #expect(fixture.center.temporarySession?.incarnation == epochB.incarnation)

        // A stale Keep bound to epoch A must not promote/destroy epoch B.
        await #expect(throws: (any Error).self) {
            _ = try await fixture.center.keepTemporaryChat(
                expectedConversationID: ordinary.id,
                expectedIncarnation: epochA.incarnation
            )
        }
        #expect(fixture.center.temporarySession?.incarnation == epochB.incarnation)
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) == nil)

        // The live epoch still works normally.
        let liveEnd = await fixture.center.endTemporaryChat(
            expectedConversationID: ordinary.id,
            expectedIncarnation: epochB.incarnation
        )
        #expect(liveEnd == .conversation(ordinary.id))
        #expect(fixture.center.temporarySession == nil)
    }

    @Test("A blocked temporary send that fails after End never restores or persists the draft (late send callback)")
    func blockedTemporarySendAfterEndDoesNotPersistDraft() async throws {
        let fixture = try await makeFixture()
        let (provider, model) = try await makeProviderModel(fixture)
        _ = provider
        _ = model
        // In-place converted session so End restores the same durable id.
        let ordinary = try await fixture.center.createConversation(title: nil)
        _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        let canary = "sendcanary-\(UUID().uuidString.prefix(8))"
        defer {
            ComposerDraftStore.shared.clear(conversationID: ordinary.id)
        }

        let viewModel = ThreadDetailViewModel(conversationID: ordinary.id, center: fixture.center)
        viewModel.draft = canary
        let gate = LaunchGate()
        fixture.center.launchTestHooks.beforeCapture = { await gate.hook() }
        defer { fixture.center.launchTestHooks.beforeCapture = nil }
        let send = Task { await viewModel.send() }
        await gate.waitUntilEntered()

        // Actual leave while the send is still parked before its launch
        // store: the temporary session and its RAM draft are destroyed.
        let target = await fixture.center.endTemporaryChat(expectedConversationID: ordinary.id)
        #expect(target == .conversation(ordinary.id))
        await gate.open()
        await send.value

        // The late failure callback must not restore the field nor persist
        // the temporary question into the ordinary draft store.
        #expect(viewModel.draft.isEmpty)
        #expect(ComposerDraftStore.shared.entry(for: ordinary.id) == nil)
        ComposerDraftStore.shared.flushAndWait()
        #expect(!(try sharedDraftFileText().contains(canary)))
    }

    /// The app's real composer-drafts document (Application Support).
    private func sharedDraftFileText() throws -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ComposerDrafts", isDirectory: true)
        let url = base.appendingPathComponent("drafts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Ordinary-data preservation on toggle
    //
    // The in-place conversion removes the durable ordinary row, so it may
    // only ever fire for a conversation that owns NOTHING durable. These
    // cases pin the resource gate: a blank chat that already owns a
    // workspace with real files, a staged attachment draft, a queued input
    // or a pending run must start a SEPARATE temporary session and lose
    // nothing when that session starts or ends.

    /// The canonical private-task root (`WorkspaceCenter.openTaskWorkspace`).
    private func privateTaskRoot(for conversationID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivateTasks", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func localCleanupCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.environment.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_workspace_cleanup") ?? 0
        }
    }

    @Test("A blank ordinary chat with a workspace and real files starts a separate temp chat and loses nothing")
    func blankWorkspaceOwnershipAndFilesSurviveTemporaryRoundTrip() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: "项目草稿")
        let workspaceStore = SQLiteWorkspaceStore(database: fixture.environment.database)
        let workspace = try await workspaceStore.ensureWorkspace(
            conversationID: ordinary.id, title: "项目草稿"
        )
        // Real user file inside the task's private root (the same canonical
        // path the workspace center uses for a private task).
        let root = privateTaskRoot(for: ordinary.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = root.appendingPathComponent("note.txt")
        let fileCanary = "user-file-\(UUID().uuidString.prefix(8))"
        try Data(fileCanary.utf8).write(to: note)
        defer { try? FileManager.default.removeItem(at: root) }
        let draftCanary = "blank-workspace-draft-\(UUID().uuidString.prefix(8))"
        ComposerDraftStore.shared.save(text: draftCanary, conversationID: ordinary.id)
        defer { ComposerDraftStore.shared.clear(conversationID: ordinary.id) }

        // No messages: the old empty-message check would have removed the
        // durable row (and with it the ownership link) and queued the
        // private files for cleanup. The resource-owning blank chat must
        // start a separate session instead.
        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(try await workspaceStore.workspaceID(conversationID: ordinary.id) == workspace.id)
        #expect(FileManager.default.fileExists(atPath: note.path))
        #expect(try String(decoding: Data(contentsOf: note), as: UTF8.self) == fileCanary)
        #expect(ComposerDraftStore.shared.text(for: ordinary.id) == draftCanary)
        #expect(try await localCleanupCount(fixture) == 0)

        // The temporary phase itself writes nothing durable for the ordinary
        // identity; ending it returns to the same chat with everything intact.
        try await fixture.center.conversationStore(for: tempID).appendMessage(PersistedMessage(
            id: UUID(), conversationID: tempID, role: "user",
            content: "ephemeral-in-separate-session", createdAt: Date()
        ))
        let target = await fixture.center.endTemporaryChat()
        #expect(target == .conversation(ordinary.id))
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(try await workspaceStore.workspaceID(conversationID: ordinary.id) == workspace.id)
        #expect(FileManager.default.fileExists(atPath: note.path))
        #expect(try String(decoding: Data(contentsOf: note), as: UTF8.self) == fileCanary)
        #expect(ComposerDraftStore.shared.text(for: ordinary.id) == draftCanary)
        #expect(try await durableCanaryCount(fixture, canary: "ephemeral-in-separate-session") == 0)
        #expect(try await localCleanupCount(fixture) == 0)
    }

    @Test("A staged ordinary attachment draft blocks in-place conversion and survives the temporary round trip")
    func stagedAttachmentDraftBlocksConversionAndSurvives() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let attachment = AttachmentRef(
            id: UUID(), conversationID: ordinary.id, kind: .document,
            displayName: "staged.txt", byteCount: 9, sha256: "cafebabe",
            storage: .applicationSupport, relativePath: "attachments/staged.txt",
            createdAt: Date()
        )
        let draftCanary = "staged-draft-\(UUID().uuidString.prefix(8))"
        ComposerDraftStore.shared.save(
            text: draftCanary, attachments: [attachment], conversationID: ordinary.id
        )
        defer { ComposerDraftStore.shared.clear(conversationID: ordinary.id) }

        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        // The ordinary row and its staged attachment draft are untouched.
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        let entry = try #require(ComposerDraftStore.shared.entry(for: ordinary.id))
        #expect(entry.text == draftCanary)
        #expect(entry.attachments.map(\.id) == [attachment.id])
        // The temporary bucket starts clean: the ordinary staged file is not
        // carried into the text-only session.
        #expect(ComposerDraftStore.shared.entry(for: tempID) == nil)

        #expect(await fixture.center.endTemporaryChat() == .conversation(ordinary.id))
        let after = try #require(ComposerDraftStore.shared.entry(for: ordinary.id))
        #expect(after.text == draftCanary)
        #expect(after.attachments.map(\.id) == [attachment.id])
    }

    @Test("A queued ordinary input blocks in-place conversion and stays queued")
    func queuedInputBlocksInPlaceConversion() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let queued = try await fixture.environment.runningInputStore.enqueue(PendingUserInput(
            conversationID: ordinary.id, content: "queued-ordinary-input"
        ))

        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(try await fixture.environment.runningInputStore.input(id: queued.id) != nil)
    }

    @Test("A pending ordinary run blocks in-place conversion and is preserved")
    func pendingRunBlocksInPlaceConversion() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let runID = UUID()
        try await fixture.environment.runStore.saveRun(RunRecord(
            id: runID, conversationID: ordinary.id, state: "preparing",
            goal: "pending-ordinary-run", startedAt: Date()
        ))

        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(try await fixture.environment.runStore.run(id: runID) != nil)
    }

    @Test("A durable-store failure fails the toggle closed: no temp session and the ordinary row stays listed")
    func storeFailureFailsToggleClosed() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        // Real failure path: the store cannot verify ownership once one of
        // the probed tables is unavailable. The toggle must surface the
        // error instead of treating the failed read as "empty" and must not
        // start a session or drop the row.
        try await fixture.environment.database.writer { db in
            try db.execute(sql: "DROP TABLE messages")
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        }
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(ordinary.id))
        #expect(fixture.center.conversations.contains { $0.id == ordinary.id })
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
    }

    // MARK: - Target-metadata guards (the row itself must be a blank ordinary chat)

    @Test("A blank Notes assistant never converts in place: purpose and identity survive")
    func blankNotesAssistantStartsSeparateTemporary() async throws {
        let fixture = try await makeFixture()
        let notes = try await fixture.center.createConversation(
            title: "文档助手", purpose: .notes
        )
        let outcome = try await fixture.center.toggleTemporaryChat(for: notes.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != notes.id)
        let row = try #require(try await fixture.environment.conversationStore.conversation(id: notes.id))
        #expect(row.purpose == .notes)
        #expect(row.title == "文档助手")
    }

    @Test("A manually named blank ordinary chat keeps its name and starts a separate temporary chat")
    func manuallyNamedBlankChatIsNotConverted() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        try await fixture.environment.conversationStore.renameConversation(
            id: ordinary.id, title: "我的任务"
        )
        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        let row = try #require(try await fixture.environment.conversationStore.conversation(id: ordinary.id))
        #expect(row.title == "我的任务")
        #expect(row.titleOrigin == .manual)
    }

    @Test("An archived blank ordinary chat stays archived and starts a separate temporary chat")
    func archivedBlankChatIsNotConverted() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        try await fixture.environment.conversationStore.setArchived(id: ordinary.id, archived: true)
        let outcome = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        let row = try #require(try await fixture.environment.conversationStore.conversation(id: ordinary.id))
        #expect(row.archivedAt != nil)
    }

    // MARK: - Suspended eligibility window (intent fence + post-await restoration)

    @Test("A staged attachment arriving while eligibility settles is preserved; the conversion is undone")
    func stagedAttachmentDuringVerificationPreservesOrdinary() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let attachment = AttachmentRef(
            id: UUID(), conversationID: ordinary.id, kind: .document,
            displayName: "late.txt", byteCount: 4, sha256: "deadbeef",
            storage: .applicationSupport, relativePath: "attachments/late.txt",
            createdAt: Date()
        )
        let canary = "late-staged-\(UUID().uuidString.prefix(8))"
        defer { ComposerDraftStore.shared.clear(conversationID: ordinary.id) }
        let gate = LaunchGate()
        fixture.center.toggleTestHooks.afterEligibilityVerify = { await gate.hook() }
        defer { fixture.center.toggleTestHooks.afterEligibilityVerify = nil }

        let attempt = Task { try await fixture.center.toggleTemporaryChat(for: ordinary.id) }
        await gate.waitUntilEntered()
        // The verified-empty removal already committed; the user stages a
        // file while the toggle's continuation is suspended on the store.
        ComposerDraftStore.shared.save(
            text: canary, attachments: [attachment], conversationID: ordinary.id
        )
        await gate.open()
        let outcome = try await attempt.value

        guard case .temporaryActive(let tempID) = outcome else {
            Issue.record("Expected a separate temporary conversation, got \(outcome)")
            return
        }
        #expect(tempID != ordinary.id)
        // The ordinary row was restored by the post-await re-check and the
        // staged attachment/text are intact; no cleanup was queued.
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        let entry = try #require(ComposerDraftStore.shared.entry(for: ordinary.id))
        #expect(entry.text == canary)
        #expect(entry.attachments.map(\.id) == [attachment.id])
        #expect(try await localCleanupCount(fixture) == 0)
        #expect(ComposerDraftStore.shared.entry(for: tempID) == nil)
    }

    @Test("A content leave while eligibility settles cancels the stale attempt and preserves the row")
    func leaveDuringEligibilityCancelsAttempt() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let gate = LaunchGate()
        fixture.center.toggleTestHooks.afterEligibilityVerify = { await gate.hook() }
        defer { fixture.center.toggleTestHooks.afterEligibilityVerify = nil }

        let attempt = Task { try await fixture.center.toggleTemporaryChat(for: ordinary.id) }
        await gate.waitUntilEntered()
        // The root's actual leave path cancels the attempt while suspended.
        fixture.center.cancelPendingTemporaryToggle(for: ordinary.id)
        await gate.open()
        let outcome = try await attempt.value

        #expect(outcome == .requiresExplicitAction(ordinary.id))
        #expect(fixture.center.temporarySession == nil)
        #expect(!fixture.center.isTemporaryConversation(ordinary.id))
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(fixture.center.conversations.contains { $0.id == ordinary.id })
        #expect(try await localCleanupCount(fixture) == 0)
    }

    @Test("A leave while a RESOURCE-OWNING chat's eligibility settles never publishes a late session")
    func leaveDuringResourcefulEligibilityDoesNotPublish() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        // A workspace makes this chat resource-owning: the atomic check
        // returns FALSE, but the store call still awaited the database.
        _ = try await SQLiteWorkspaceStore(database: fixture.environment.database)
            .ensureWorkspace(conversationID: ordinary.id, title: "kept")
        let gate = LaunchGate()
        fixture.center.toggleTestHooks.afterEligibilityVerify = { await gate.hook() }
        defer { fixture.center.toggleTestHooks.afterEligibilityVerify = nil }

        let attempt = Task { try await fixture.center.toggleTemporaryChat(for: ordinary.id) }
        await gate.waitUntilEntered()
        fixture.center.cancelPendingTemporaryToggle(for: ordinary.id)
        await gate.open()
        let outcome = try await attempt.value

        #expect(outcome == .requiresExplicitAction(ordinary.id))
        #expect(fixture.center.temporarySession == nil)
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
        #expect(fixture.center.conversations.contains { $0.id == ordinary.id })
    }

    @Test("A replacement session installed while an attempt settles is never overwritten")
    func replacementSessionBlocksLateAttempt() async throws {
        let fixture = try await makeFixture()
        let first = try await fixture.center.createConversation(title: nil)
        let gate = LaunchGate()
        fixture.center.toggleTestHooks.afterEligibilityVerify = { await gate.hook() }
        defer { fixture.center.toggleTestHooks.afterEligibilityVerify = nil }

        let attempt = Task { try await fixture.center.toggleTemporaryChat(for: first.id) }
        await gate.waitUntilEntered()
        // A replacement session is published while the first attempt settles
        // (the user left and started another temporary chat).
        let replacementID = try await fixture.center.startTemporarySession(initialDraft: "")
        await gate.open()
        let outcome = try await attempt.value

        #expect(outcome == .requiresExplicitAction(first.id))
        #expect(fixture.center.temporarySession?.conversation.id == replacementID)
        // The first attempt's committed removal was restored: no ordinary
        // record was lost and no late session overwrote the replacement.
        #expect(try await fixture.environment.conversationStore.conversation(id: first.id) != nil)
        await fixture.center.endTemporaryChat()
    }

    @Test("A second toggle during the suspended window is a no-op; exactly one session publishes")
    func secondToggleDuringSuspensionIsNoOp() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.center.createConversation(title: nil)
        let gate = LaunchGate()
        fixture.center.toggleTestHooks.afterEligibilityVerify = { await gate.hook() }
        defer { fixture.center.toggleTestHooks.afterEligibilityVerify = nil }

        let first = Task { try await fixture.center.toggleTemporaryChat(for: ordinary.id) }
        await gate.waitUntilEntered()
        let second = try await fixture.center.toggleTemporaryChat(for: ordinary.id)
        #expect(second == .requiresExplicitAction(ordinary.id))
        #expect(fixture.center.temporarySession == nil)
        await gate.open()
        let outcome = try await first.value

        #expect(outcome == .temporaryActive(ordinary.id))
        #expect(fixture.center.isTemporaryConversation(ordinary.id))
        // Exactly one session, and a normal End restores the same row.
        #expect(await fixture.center.endTemporaryChat() == .conversation(ordinary.id))
        #expect(try await fixture.environment.conversationStore.conversation(id: ordinary.id) != nil)
    }
}

// MARK: - Scripted providers for the App-host temporary-run tests
//
// These adapters implement the public `ProviderAdapter` contract only; the
// tests install them through the center's test-only override seam, so no
// network request, credential or paid model is ever used.

/// Deterministic failure for runs that must reach the provider stage without
/// any network request (the hermetic default).
private struct FailingProviderAdapter: ProviderAdapter {
    struct ProviderUnavailable: Error {}

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderUnavailable())
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

/// First turn: one structured tool call carrying a synthetic sensitive
/// argument; later turns: a short final answer.
private final class ScriptedToolCallProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var turn = 0
    private var streams = 0

    func nextTurn() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = turn
        turn += 1
        return value
    }

    func noteStream() {
        lock.lock()
        defer { lock.unlock() }
        streams += 1
    }

    var streamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams
    }
}

private struct ScriptedToolCallProvider: ProviderAdapter {
    let state: ScriptedToolCallProviderState
    let canary: String

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        state.noteStream()
        let turn = state.nextTurn()
        let canary = canary
        return AsyncThrowingStream { continuation in
            Task {
                if turn == 0,
                   let call = try? ToolCall(
                       id: "call-canary-1",
                       toolName: "shell.exec",
                       argumentsJSON: Data(#"{"command":"echo hi","token":"\#(canary)"}"#.utf8),
                       scope: .local
                   ) {
                    continuation.yield(.toolRequest(call))
                } else {
                    continuation.yield(.textDelta(.init(text: "done")))
                }
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

/// Streams one delta and then never finishes: the run stays parked at the
/// provider until something cancels it.
private final class HangingProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var streams = 0
    private var terminations = 0

    func noteStream() {
        lock.lock()
        defer { lock.unlock() }
        streams += 1
    }

    func noteTermination() {
        lock.lock()
        defer { lock.unlock() }
        terminations += 1
    }

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams > 0
    }

    var terminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminations > 0
    }
}

private struct HangingProvider: ProviderAdapter {
    let state: HangingProviderState

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        state.noteStream()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in state.noteTermination() }
            continuation.yield(.textDelta(.init(text: "streaming")))
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}
