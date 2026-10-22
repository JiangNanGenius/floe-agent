// FloeAppTests — conversation-local execution mode retention.
//
// Pins the closure this lane exists for: `AgentExecutionMode.chat` and
// `.agent` both persist as `ConversationMode.chat`, so the durable
// conversation record cannot distinguish "Chat (public web + attached reads)"
// from a task-capable Agent. The schema-51 per-conversation snapshot is the
// only honest authority. These tests use the real ConversationCenter, the real
// SQLite preference store and a real ThreadDetailViewModel over the in-memory
// preview database; no AgentRuntime host and no provider I/O are involved
// (the one startTask seed case asserts the snapshot inside the launch
// transaction window and never awaits the deferred provider loop).

import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.ChatModeRestoration")
@MainActor
struct ChatModeRestorationTests {
    /// Suite-local fixture. The suite is `@MainActor`, so the fixture stays
    /// MainActor-isolated too: no `@unchecked Sendable` wrapper and no
    /// concurrency-check bypass.
    @MainActor
    private final class Fixture {
        let environment: AppEnvironment
        let center: ConversationCenter

        init() {
            environment = AppEnvironment.preview()
            center = ConversationCenter(environment: environment)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture()
        // The preview environment is un-migrated; the schema must exist
        // before any store write.
        try await fixture.environment.database.migrate()
        return fixture
    }

    private func makeConversation(_ fixture: Fixture) async throws -> UUID {
        let id = UUID()
        try await SQLiteConversationStore(database: fixture.environment.database)
            .saveConversation(ConversationRecord(
                id: id, title: "chat", createdAt: Date(), updatedAt: Date()))
        return id
    }

    private func store(_ fixture: Fixture) -> SQLiteChatPreferenceStore {
        SQLiteChatPreferenceStore(database: fixture.environment.database)
    }

    private func snapshot(
        _ fixture: Fixture,
        _ conversationID: UUID
    ) async throws -> ChatConversationPreferences? {
        try await store(fixture).preferences(conversationID: conversationID)
    }

    /// Bounded wait for the asynchronous (fire-and-forget) persistence of an
    /// explicit composer selection. The UI keeps the RAM choice immediately;
    /// only the durable write is asynchronous.
    private func waitForSavedMode(
        _ raw: String,
        fixture: Fixture,
        conversationID: UUID
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if try await snapshot(fixture, conversationID)?.preferredExecutionMode == raw {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await snapshot(fixture, conversationID)?.preferredExecutionMode == raw,
                "the explicit mode choice was not persisted before the deadline")
    }

    // MARK: - Resolution semantics

    @Test("a legacy conversation with no saved choice keeps the Agent default")
    func legacyConversationDefaultsToAgent() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        let resolution = await fixture.center.preferredExecutionMode(for: conversationID)
        #expect(resolution == ConversationCenter.PreferredExecutionModeResolution.legacyDefaultAgent)
        #expect(resolution.mode == .agent)
        #expect(resolution.isRemembered == false)
    }

    @Test("every saved valid mode is remembered and restored")
    func savedChoicesAreRemembered() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        for mode in [AgentExecutionMode.chat, .agent, .plan, .goal] {
            try await store(fixture).updatePreferredExecutionMode(
                mode.rawValue, conversationID: conversationID)
            let resolution = await fixture.center.preferredExecutionMode(for: conversationID)
            #expect(resolution.mode == mode)
            #expect(resolution.isRemembered)
            #expect(resolution.needsRepair == false)
            #expect(resolution.readFailed == false)
        }
    }

    @Test("an unreadable stored mode fails closed to Chat, never Agent")
    func unreadableStoredModeFailsClosedToChat() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        // A present-but-unknown value is corrupt data, not a legacy row.
        try await store(fixture).savePreferences(
            ChatConversationPreferences(preferredExecutionMode: "summarize"),
            conversationID: conversationID)
        let resolution = await fixture.center.preferredExecutionMode(for: conversationID)
        #expect(resolution.mode == .chat)
        #expect(resolution.isRemembered)
        #expect(resolution.needsRepair)
    }

    @Test("a corrupt snapshot row is not mistaken for a legacy absent row")
    func corruptSnapshotFailsClosedToChat() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        try await fixture.environment.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_chat_preferences (conversation_id, preferences_json, updated_at)
                    VALUES (?, 'not-json', datetime('now'))
                    """,
                arguments: [conversationID.uuidString])
        }
        let resolution = await fixture.center.preferredExecutionMode(for: conversationID)
        #expect(resolution.mode == .chat)
        #expect(resolution.needsRepair)
        // The composer may still choose Agent consciously: the fail-closed
        // value must not block an explicit selection.
        try await fixture.center.setPreferredExecutionMode(.agent, for: conversationID)
        let saved = try #require(try await snapshot(fixture, conversationID))
        #expect(saved.preferredExecutionMode == "agent")
        let repaired = await fixture.center.preferredExecutionMode(for: conversationID)
        #expect(repaired == ConversationCenter.PreferredExecutionModeResolution(
            mode: .agent, isRemembered: true, needsRepair: false, readFailed: false))
    }

    @Test("a selection made while the durable write is in flight is visible to a new view")
    func inFlightSelectionWinsOverOlderDurableMode() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        try await store(fixture).updatePreferredExecutionMode("agent", conversationID: conversationID)
        // Fire the explicit choice without awaiting the durable write, then
        // read exactly as a freshly created view would.
        let pendingWrite = Task { @MainActor in
            try await fixture.center.setPreferredExecutionMode(.chat, for: conversationID)
        }
        var resolution = await fixture.center.preferredExecutionMode(for: conversationID)
        var attempts = 0
        while resolution.mode != .chat, attempts < 100 {
            attempts += 1
            await Task.yield()
            resolution = await fixture.center.preferredExecutionMode(for: conversationID)
        }
        #expect(resolution.mode == .chat)
        #expect(resolution.isRemembered)
        try await pendingWrite.value
        let saved = try #require(try await snapshot(fixture, conversationID))
        #expect(saved.preferredExecutionMode == "chat")
    }

    // MARK: - Production writers preserve each other

    @Test("reasoning and mode writers preserve the sibling field through the center")
    func centerFieldWritersPreserveEachOther() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        try await fixture.center.setChatReasoningPreference(.high, for: conversationID)
        try await fixture.center.setPreferredExecutionMode(.chat, for: conversationID)
        var saved = try #require(try await snapshot(fixture, conversationID))
        #expect(saved.chatReasoning == .high)
        #expect(saved.preferredExecutionMode == "chat")

        // The exact regression: a later reasoning change must not erase the
        // Chat choice (previously a whole-snapshot read/write did).
        try await fixture.center.setChatReasoningPreference(.low, for: conversationID)
        saved = try #require(try await snapshot(fixture, conversationID))
        #expect(saved.chatReasoning == .low)
        #expect(saved.preferredExecutionMode == "chat")

        // And a later explicit mode change must not erase reasoning.
        try await fixture.center.setPreferredExecutionMode(.agent, for: conversationID)
        saved = try #require(try await snapshot(fixture, conversationID))
        #expect(saved.chatReasoning == .low)
        #expect(saved.preferredExecutionMode == "agent")
    }

    // MARK: - Thread view recreation

    @Test("a Home-style Chat choice restores in a recreated thread view")
    func chatChoiceSurvivesThreadViewRecreation() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        try await store(fixture).updatePreferredExecutionMode("chat", conversationID: conversationID)

        let first = ThreadDetailViewModel(conversationID: conversationID, center: fixture.center)
        await first.load()
        #expect(first.agentMode == .chat)

        // Reopening (a new view over the same durable conversation) must not
        // fall back to the historical Agent default.
        let second = ThreadDetailViewModel(conversationID: conversationID, center: fixture.center)
        await second.load()
        #expect(second.agentMode == .chat)
    }

    @Test("an explicit Agent switch persists and survives thread view recreation")
    func explicitAgentSwitchSurvivesRecreation() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        try await store(fixture).updatePreferredExecutionMode("chat", conversationID: conversationID)

        let first = ThreadDetailViewModel(conversationID: conversationID, center: fixture.center)
        await first.load()
        #expect(first.agentMode == .chat)
        first.selectAgentMode(.agent)
        #expect(first.agentMode == .agent)
        try await waitForSavedMode("agent", fixture: fixture, conversationID: conversationID)

        let second = ThreadDetailViewModel(conversationID: conversationID, center: fixture.center)
        await second.load()
        #expect(second.agentMode == .agent)
    }

    @Test("an unreadable saved mode leaves the composer in Chat with a notice")
    func unreadableSavedModeWarnsWithoutEscalating() async throws {
        let fixture = try await makeFixture()
        let conversationID = try await makeConversation(fixture)
        try await store(fixture).savePreferences(
            ChatConversationPreferences(preferredExecutionMode: "summarize"),
            conversationID: conversationID)
        let view = ThreadDetailViewModel(conversationID: conversationID, center: fixture.center)
        await view.load()
        #expect(view.agentMode == .chat)
        #expect(view.actionError != nil)
    }

    // MARK: - First-round seed (Home typed chat / new voice chat)

    @Test("a Home Chat first round seeds the durable mode before the thread opens")
    func homeChatFirstRoundSeedsChatMode() async throws {
        let fixture = try await makeFixture()
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://mode-seed.example/v1")!,
            displayName: "Mode Seed Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "mode-seed-model",
            displayName: "Mode Seed Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.tools])
        try await fixture.environment.configurationStore.saveProvider(provider)
        try await fixture.environment.configurationStore.saveModel(model)

        let started = try await fixture.center.startTask(
            goal: "hello chat",
            title: "hello chat",
            provider: provider,
            model: model,
            executionMode: .chat,
            startOrigin: .explicitUserAction)
        // The seed is written inside the launch window: navigation (a new
        // thread view) happens only after startTask returns.
        let saved = try await snapshot(fixture, started.conversationID)
        #expect(saved?.preferredExecutionMode == "chat")

        // A non-chat first round leaves the legacy Agent default untouched so
        // legacy agent/plan/goal reopen behavior is unchanged.
        let agentStarted = try await fixture.center.startTask(
            goal: "hello agent",
            title: "hello agent",
            provider: provider,
            model: model,
            executionMode: .agent,
            startOrigin: .explicitUserAction)
        let agentSaved = try await snapshot(fixture, agentStarted.conversationID)
        #expect(agentSaved?.preferredExecutionMode == nil)
    }

    // MARK: - Temporary sessions

    @Test("a temporary session never reaches the durable preference table")
    func temporarySessionNeverWritesMode() async throws {
        let fixture = try await makeFixture()
        let temporaryID = try await fixture.center.startTemporarySession()
        try await fixture.center.setPreferredExecutionMode(.chat, for: temporaryID)
        let rows = try await fixture.environment.database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM conversation_chat_preferences WHERE conversation_id = ?",
                arguments: [temporaryID.uuidString]) ?? 0
        }
        #expect(rows == 0)
        let resolution = await fixture.center.preferredExecutionMode(for: temporaryID)
        #expect(resolution == ConversationCenter.PreferredExecutionModeResolution.legacyDefaultAgent)
    }
}
