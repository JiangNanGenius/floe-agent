#if DEBUG && canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence

/// Only the explicitly named synthetic records are prepared or removed.
/// No model request or schedule execution is used for UI qualification.
enum LinkedScheduleUIFixture {
    static let conversationID = UUID(uuidString: "A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A003")!
    private static let ids = [
        UUID(uuidString: "34F9DAF1-531B-43B4-99B4-020D01163061")!,
        UUID(uuidString: "34F9DAF1-531B-43B4-99B4-020D01163062")!
    ]

    static func prepareIfRequested(database: DatabaseManager) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return }
        let store = SQLiteTaskScheduleStore(database: database)
        if arguments.contains("--ui-test-linked-schedule-cleanup") {
            for id in ids {
                if let record = try await store.schedule(id: id),
                   record.originConversationID == conversationID,
                   record.title.hasPrefix("UI 关联计划") {
                    try await store.delete(id: id)
                }
            }
            return
        }
        guard arguments.contains("--ui-test-linked-schedule") else { return }
        for (index, id) in ids.enumerated() {
            // Distant times prevent a failed UI test from initiating paid
            // work; the test removes its own fixed records on completion.
            let date = Date().addingTimeInterval(Double(30 + index) * 86_400)
            try await store.save(TaskScheduleRecord(
                id: id, title: "UI 关联计划 \(index + 1)",
                prompt: "Synthetic linked-plan display. Do not execute during UI qualification.",
                cadence: .once, scheduledAt: date,
                originConversationID: conversationID
            ))
        }
    }
}
#endif
