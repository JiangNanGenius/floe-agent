// FloeApp — Foreground notification banner center.
//
// When the app is foreground, `TaskNotificationDecision` routes terminal and
// approval events here instead of submitting a system notification, so the
// user sees one in-app banner rather than a duplicated system alert. The
// banner carries the same `BackgroundWorkDeepLink` identity a notification
// would carry; tapping it performs the same route.

#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore

@MainActor
final class TaskBannerCenter: ObservableObject {
    /// App-wide banner surface. One instance keeps the coordinator, the
    /// settings previews and every scene reading the same banner.
    static let shared = TaskBannerCenter()

    struct Banner: Identifiable, Equatable {
        let id: UUID
        let title: String
        let body: String
        let deepLink: BackgroundWorkDeepLink
    }

    @Published private(set) var banner: Banner?
    private var hideTask: Task<Void, Never>?

    /// How long a banner stays visible before it auto-dismisses.
    public static let presentationDuration: TimeInterval = 4

    func present(
        title: String,
        body: String,
        deepLink: BackgroundWorkDeepLink,
        duration: TimeInterval = TaskBannerCenter.presentationDuration
    ) {
        hideTask?.cancel()
        let id = UUID()
        banner = Banner(id: id, title: title, body: body, deepLink: deepLink)
        hideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            await MainActor.run { self?.dismiss(id: id) }
        }
    }

    func dismiss(id: UUID? = nil) {
        guard id == nil || banner?.id == id else { return }
        hideTask?.cancel()
        hideTask = nil
        banner = nil
    }
}
#endif
