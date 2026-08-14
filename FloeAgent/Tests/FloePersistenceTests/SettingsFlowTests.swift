// FloePersistenceTests — Settings-flow level persistence contract.
// See docs/ARCHITECTURE_SETTINGS.md: cross-session preferences round-trip
// through app_settings, typed values survive, and a cleared store reads
// back empty. UI-only flows (confirmation dialogs, share sheet, idiom
// routing) are covered by XCUITest in T10's FloeAgentUITests, not here.

import Foundation
import Testing
@testable import FloePersistence
import FloeCore

@Suite("FloePersistence.SettingsFlow")
struct SettingsFlowTests {

    private func makeStore() async throws -> SQLiteSettingsStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return SQLiteSettingsStore(database: database)
    }

    @Test("Full AppSettings round-trip through individual keys")
    func appSettingsRoundTrip() async throws {
        let store = try await makeStore()
        let settings = AppSettings(
            defaultAgentMode: .approvalModel,
            execution: ExecutionSettings(
                target: .local, timeoutSeconds: 120, maxOutputBytes: 32_768, savesArtifacts: false
            ),
            defaultStartPage: .chat,
            defaultWorkspaceID: UUID(),
            sshDefaults: RemoteSessionDefaults(autoReconnect: false, keepAlive: true),
            vncDefaults: RemoteSessionDefaults(autoReconnect: true, keepAlive: false),
            idleDisconnectMinutes: 30
        )

        // Write each field under its well-known key, mirroring SettingsCenter.
        try await store.setValue(settings.defaultAgentMode, forKey: AppSettingsKey.defaultAgentMode)
        try await store.setValue(settings.execution.timeoutSeconds, forKey: AppSettingsKey.executionTimeoutSeconds)
        try await store.setValue(settings.execution.maxOutputBytes, forKey: AppSettingsKey.maxOutputBytes)
        try await store.setValue(settings.execution.savesArtifacts, forKey: AppSettingsKey.savesArtifacts)
        try await store.setValue(settings.defaultStartPage, forKey: AppSettingsKey.defaultStartPage)
        if let workspaceID = settings.defaultWorkspaceID {
            // Pass the UUID (not uuidString): the raw String overload would
            // store a bare unquoted value that fails JSON decode on read.
            try await store.setValue(workspaceID, forKey: AppSettingsKey.defaultWorkspace)
        }
        try await store.setValue(settings.sshDefaults, forKey: AppSettingsKey.sshDefaults)
        try await store.setValue(settings.vncDefaults, forKey: AppSettingsKey.vncDefaults)
        try await store.setValue(settings.idleDisconnectMinutes, forKey: AppSettingsKey.idleDisconnectMinutes)

        // Read back through the typed helpers.
        #expect(try await store.value(forKey: AppSettingsKey.defaultAgentMode, as: AgentMode.self) == .approvalModel)
        #expect(try await store.value(forKey: AppSettingsKey.executionTimeoutSeconds, as: Int.self) == 120)
        #expect(try await store.value(forKey: AppSettingsKey.maxOutputBytes, as: Int.self) == 32_768)
        #expect(try await store.value(forKey: AppSettingsKey.savesArtifacts, as: Bool.self) == false)
        #expect(try await store.value(forKey: AppSettingsKey.defaultStartPage, as: StartPage.self) == .chat)
        // defaultWorkspace is written as a JSON string (SettingsCenter
        // persists `id.uuidString`); decode as String, then build the UUID.
        let storedWorkspace = try await store.value(forKey: AppSettingsKey.defaultWorkspace, as: String.self)
        #expect(storedWorkspace == settings.defaultWorkspaceID?.uuidString)
        #expect(storedWorkspace.flatMap(UUID.init(uuidString:)) == settings.defaultWorkspaceID)
        #expect(try await store.value(forKey: AppSettingsKey.sshDefaults, as: RemoteSessionDefaults.self)
                == settings.sshDefaults)
        #expect(try await store.value(forKey: AppSettingsKey.vncDefaults, as: RemoteSessionDefaults.self)
                == settings.vncDefaults)
        #expect(try await store.value(forKey: AppSettingsKey.idleDisconnectMinutes, as: Int.self) == 30)
    }

    @Test("Removing every key leaves an empty store")
    func clearLeavesEmptyStore() async throws {
        let store = try await makeStore()
        try await store.setValue(AgentMode.human, forKey: AppSettingsKey.defaultAgentMode)
        try await store.setValue(15, forKey: AppSettingsKey.idleDisconnectMinutes)
        #expect(try await store.allValues().count == 2)

        try await store.removeValue(forKey: AppSettingsKey.defaultAgentMode)
        try await store.removeValue(forKey: AppSettingsKey.idleDisconnectMinutes)
        #expect(try await store.allValues().isEmpty)
    }

    @Test("Redaction strips credential shapes from a diagnostics payload")
    func diagnosticsPayloadIsRedacted() {
        let payload = """
        version: 1.0
        keychain: available(read/write ok)
        api_key=sk-live1234567890abcdef
        authorization: Bearer eyJhbGciOiJ9.token
        """
        let redacted = SecretRedactor.redact(payload)
        #expect(!redacted.contains("sk-live1234567890abcdef"))
        #expect(!redacted.contains("eyJhbGciOiJ9.token"))
        #expect(redacted.contains("⟨redacted⟩"))
        // Non-secret lines survive untouched.
        #expect(redacted.contains("version: 1.0"))
        #expect(redacted.contains("keychain: available(read/write ok)"))
    }
}
