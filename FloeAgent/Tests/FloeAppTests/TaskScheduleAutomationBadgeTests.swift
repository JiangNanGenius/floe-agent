// Behavior contracts for the setup sheet's ONE-badge entry.
//
// The routed decisions behind the single tap live in the model (exactly
// what the badge closure calls), so they are pinned behaviorally here —
// no source-mirror checks:
//   • the fallback target is Apple's documented `shortcuts://` scheme;
//   • with NO template the tap only opens Shortcuts and cannot enter the
//     attempt/monitoring state machine at all — no invented self-
//     confirmation obligation, no failure-to-default evidence (opening
//     the Add page or the app proves nothing about any import; a real
//     system firing remains the strongest observable evidence);
//   • with a template the same call runs the real native import handoff
//     (see the badge cases in TaskScheduleShortcutImportTests).
// Visual acceptance of the single-control layout belongs to Main. No UI is
// instantiated and no system component is contacted.

#if canImport(UIKit) && canImport(SwiftUI) && DEBUG
import Foundation
import Testing
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.TaskScheduleAutomationBadge")
@MainActor
struct TaskScheduleAutomationBadgeTests {

    @Test("The documented shortcuts:// fallback URL is exactly Apple's scheme")
    func badgeFallbackScheme() {
        #expect(TaskScheduleShortcutImport.shortcutsAppURL.scheme == "shortcuts")
        #expect(TaskScheduleShortcutImport.shortcutsAppURL.host == nil)
    }

    @Test("Badge tap keeps the no-template path record-free")
    func badgeTapWithoutTemplateRecordsNothing() async throws {
        // The exact seam the badge's single closure calls. With no template
        // performBadgeTap must NOT touch the attempt state machine at all.
        let suiteName = "floe.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = TaskScheduleCleanupReminderStore(database: database)
        let scheduleID = UUID()
        let model = TaskScheduleShortcutImport(
            templateReader: { nil }, defaults: suite)
        model.refresh(scheduleID: scheduleID, title: "Badge only", cleanupStore: store)
        var opened: [URL] = []
        model.shortcutsAppOpener = { opened.append($0) }
        await model.performBadgeTap()
        #expect(opened == [TaskScheduleShortcutImport.shortcutsAppURL])
        #expect(model.evidence == nil)
        // Durable truth too: opening the Shortcuts app starts no monitoring.
        #expect(try await store.reminder(scheduleID: scheduleID) == nil)
        #expect(try await store.openReminders().isEmpty)
    }
}
#endif
