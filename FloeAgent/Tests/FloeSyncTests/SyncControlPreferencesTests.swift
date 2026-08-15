import Foundation
import Testing
@testable import FloeSync

@Suite("Sync control preferences")
struct SyncControlPreferencesTests {
    @Test("Defaults enable both sync layers and persist independently")
    func defaultsAndIndependentPersistence() throws {
        let suite = "org.floeagent.tests.sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SyncControlPreferences.load(from: defaults) == SyncControlPreferences())

        SyncControlPreferences(
            overallEnabled: true,
            configurationEnabled: false
        ).save(to: defaults)
        #expect(SyncControlPreferences.load(from: defaults).overallEnabled)
        #expect(!SyncControlPreferences.load(from: defaults).configurationEnabled)
    }

    @Test("Pausing the engine preserves an honest paused status")
    func enginePause() async {
        let engine = ConfigSyncEngine()
        await engine.setSynchronizationEnabled(false)
        let disabled = await engine.synchronizationEnabled
        let pausedStatus = await engine.status
        #expect(!disabled)
        #expect(pausedStatus == .paused)

        await engine.setSynchronizationEnabled(true)
        let enabled = await engine.synchronizationEnabled
        #expect(enabled)
    }
}
