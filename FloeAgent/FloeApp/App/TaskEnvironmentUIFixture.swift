#if DEBUG && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// Exact synthetic ownership; no model request, remote host or VM startup.
@MainActor
enum TaskEnvironmentUIFixture {
    static let id = UUID(uuidString: "4C19EFD3-C19E-450F-8E5A-306000000001")!
    static func prepareIfRequested(environment: AppEnvironment) async throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-ui-testing"), args.contains("--ui-test-task-environment") || args.contains("--ui-test-task-environment-cleanup") else { return }
        if let existing = try await environment.conversationStore.conversation(id: id) {
            guard existing.title == "UI 运行位置" else { throw FloeError.validationFailed("Synthetic task ownership changed") }
            if args.contains("--ui-test-task-environment-cleanup") {
                try await environment.conversationCenter.deleteConversation(id: id)
                try await removeOwnedLocalEnvironments(environment: environment)
            }
            return
        }
        guard args.contains("--ui-test-task-environment") else { return }
        // A previous interrupted test can leave an unreferenced session record.
        // Only this fixed synthetic owner and local sessions are disposable.
        try await removeOwnedLocalEnvironments(environment: environment)
        try await environment.conversationStore.saveConversation(.init(id: id, title: "UI 运行位置", createdAt: Date(), updatedAt: Date()))
        _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "UI 运行位置")
    }

    private static func removeOwnedLocalEnvironments(environment: AppEnvironment) async throws {
        for record in await environment.environmentRegistry.containersOwned(by: id.uuidString)
            where record.kind == .session && record.effectiveExecutionBackend == .linuxVM {
            try await FloePlatformServices.shared.deleteEnvironment(id: record.id)
        }
    }
}
#endif
