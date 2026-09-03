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

#if canImport(CloudKit)
    @Test("Confirmed cloud release removes only an authorized local file")
    func confirmedReleaseLocalFileBoundary() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let materialDirectory = temporaryRoot
            .appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: materialDirectory,
            withIntermediateDirectories: true
        )
        let authorizedFile = materialDirectory.appendingPathComponent("cloud.png")
        try Data("cloud-asset".utf8).write(to: authorizedFile)

        #expect(try CanvasCloudAssetLocalFileDeletion.remove(
            relativePath: "Materials/cloud.png",
            under: temporaryRoot
        ))
        #expect(!FileManager.default.fileExists(atPath: authorizedFile.path))

        let outsideFile = temporaryRoot
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outsideFile) }
        try Data("must-stay".utf8).write(to: outsideFile)
        #expect(throws: (any Error).self) {
            try CanvasCloudAssetLocalFileDeletion.remove(
                relativePath: "../\(outsideFile.lastPathComponent)",
                under: temporaryRoot
            )
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }
#endif
}
