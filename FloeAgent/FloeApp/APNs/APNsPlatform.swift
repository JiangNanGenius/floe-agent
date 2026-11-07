// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import UserNotifications

/// The existing system services. Injection lets contracts exercise opt-out,
/// OS token renewal and cancellation without registering a real device.
@MainActor struct APNsPlatform {
    var authorization: @MainActor @Sendable () async -> APNsVisibleAuthorization
    var requestVisibleAuthorization: @MainActor @Sendable () async throws -> Void
    var register: @MainActor @Sendable () -> Void
    var unregister: @MainActor @Sendable () -> Void
    var backgroundRefreshAvailable: @MainActor @Sendable () -> Bool
    var installChannel: @MainActor @Sendable () async -> APNsInstallChannel
    var isForeground: @MainActor @Sendable () -> Bool = { UIApplication.shared.applicationState == .active }

    static var live: Self {
        .init(authorization: {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized: return .authorized
            case .provisional: return .provisional
            case .ephemeral: return .ephemeral
            @unknown default: return .unknown
            }
        }, requestVisibleAuthorization: {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }, register: {
            UIApplication.shared.registerForRemoteNotifications()
        }, unregister: {
            UIApplication.shared.unregisterForRemoteNotifications()
        }, backgroundRefreshAvailable: {
            UIApplication.shared.backgroundRefreshStatus == .available
        }, installChannel: { await APNsInstallChannelDetector.detect() })
    }
}
#endif
