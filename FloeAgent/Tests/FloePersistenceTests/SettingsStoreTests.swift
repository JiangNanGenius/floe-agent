// FloePersistenceTests — SettingsStore behaviour: raw JSON and Codable
// round-trips, overwrite, removal, deterministic allValues ordering.
// See docs/ARCHITECTURE_SETTINGS.md §3.1.

import Foundation
import Testing
@testable import FloePersistence
import FloeCore

@Suite("FloePersistence.SettingsStore")
struct SettingsStoreTests {

    private func makeStore() async throws -> SQLiteSettingsStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return SQLiteSettingsStore(database: database)
    }

    @Test("get/set/remove round-trip raw JSON")
    func rawRoundTrip() async throws {
        let store = try await makeStore()
        #expect(try await store.value(forKey: "agent.defaultMode") == nil)

        try await store.setValue("\"human\"", forKey: "agent.defaultMode")
        #expect(try await store.value(forKey: "agent.defaultMode") == "\"human\"")

        try await store.removeValue(forKey: "agent.defaultMode")
        #expect(try await store.value(forKey: "agent.defaultMode") == nil)

        // Removing an absent key is a no-op.
        try await store.removeValue(forKey: "agent.defaultMode")
        #expect(try await store.value(forKey: "agent.defaultMode") == nil)
    }

    @Test("set overwrites an existing key and bumps updated_at")
    func overwriteSemantics() async throws {
        let store = try await makeStore()
        try await store.setValue("300", forKey: "exec.timeoutSeconds")
        try await store.setValue("600", forKey: "exec.timeoutSeconds")
        #expect(try await store.value(forKey: "exec.timeoutSeconds") == "600")
        #expect(try await store.allValues().count == 1)
    }

    @Test("Codable helpers round-trip typed values")
    func codableRoundTrip() async throws {
        let store = try await makeStore()

        try await store.setValue(AgentMode.approvalModel, forKey: AppSettingsKey.defaultAgentMode)
        let mode = try await store.value(forKey: AppSettingsKey.defaultAgentMode, as: AgentMode.self)
        #expect(mode == .approvalModel)

        let defaults = RemoteSessionDefaults(autoReconnect: false, keepAlive: true)
        try await store.setValue(defaults, forKey: AppSettingsKey.sshDefaults)
        let loaded = try await store.value(forKey: AppSettingsKey.sshDefaults, as: RemoteSessionDefaults.self)
        #expect(loaded == defaults)

        try await store.setValue(ExecutionSettings(timeoutSeconds: 120, maxOutputBytes: 32_768),
                                 forKey: "exec.bundle")
        let bundle = try await store.value(forKey: "exec.bundle", as: ExecutionSettings.self)
        #expect(bundle?.timeoutSeconds == 120)
        #expect(bundle?.maxOutputBytes == 32_768)

        // Absent key decodes to nil.
        #expect(try await store.value(forKey: "missing", as: AgentMode.self) == nil)
    }

    @Test("allValues returns every key sorted deterministically")
    func allValuesDeterministic() async throws {
        let store = try await makeStore()
        try await store.setValue("\"dark\"", forKey: "ui.appearance")
        try await store.setValue("\"human\"", forKey: "agent.defaultMode")
        try await store.setValue("15", forKey: "remote.idleDisconnectMinutes")

        let all = try await store.allValues()
        #expect(all.count == 3)
        #expect(all["agent.defaultMode"] == "\"human\"")
        #expect(all["remote.idleDisconnectMinutes"] == "15")
        #expect(all.keys.sorted() == ["agent.defaultMode", "remote.idleDisconnectMinutes", "ui.appearance"])
    }

    @Test("Corrupted JSON surfaces as storageCorrupted on typed decode")
    func corruptedJSONThrows() async throws {
        let store = try await makeStore()
        try await store.setValue("{not-json", forKey: "agent.defaultMode")
        await #expect(throws: FloeError.self) {
            _ = try await store.value(forKey: "agent.defaultMode", as: AgentMode.self)
        }
    }

    // MARK: WorkspaceStore grant management (allGrants / deleteGrant)

    @Test("allGrants lists every grant and deleteGrant removes one")
    func grantManagement() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteWorkspaceStore(database: database)

        let first = StoredGrant(toolName: "workspace.writeFile", paths: ["Sources/"], policyName: "human")
        let second = StoredGrant(
            toolName: "ssh.execute", singleUse: false, policyName: "autopilot",
            expiresAt: Date(timeIntervalSince1970: 1_000) // already expired — still listed
        )
        try await store.saveGrant(first)
        try await store.saveGrant(second)

        var all = try await store.allGrants()
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)) == [first.id, second.id])

        try await store.deleteGrant(id: first.id)
        all = try await store.allGrants()
        #expect(all.count == 1)
        #expect(all[0].id == second.id)

        // Deleting an absent id is a no-op.
        try await store.deleteGrant(id: first.id)
        #expect(try await store.allGrants().count == 1)
    }
}
