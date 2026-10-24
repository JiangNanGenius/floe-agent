#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSkills

/// The service, rather than a view's Task, owns a complete serialized batch.
@MainActor
final class SkillUpdateCoordinator: ObservableObject {
    @Published private(set) var states: [String: SkillUpdateAvailability] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var reviewSkillID: String?
    private var task: Task<Void, Never>?

    func set(_ state: SkillUpdateAvailability, for id: String) {
        states[id] = state
    }

    func removeState(for id: String) { states[id] = nil }

    func presentReview(for id: String) { reviewSkillID = id }

    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !isRunning else { return }
        reviewSkillID = nil
        isRunning = true
        task = Task { [self] in
            await operation()
            isRunning = false
            task = nil
        }
    }
}
#endif
