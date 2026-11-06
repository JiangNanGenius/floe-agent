// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit

/// Keeps the existing UIApplication and UNNotificationCenter delegates.
/// Raw platform dictionaries are decoded before a MainActor hop.
nonisolated enum APNsNotificationIntake {
    typealias Center = @MainActor @Sendable () -> APNsCenter?
    static func background(userInfo: [AnyHashable: Any], center: @escaping Center,
                           completion: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        guard userInfo["floe"] != nil else { return false }
        let once = APNsFetchCompletion(completion)
        guard let payload = try? APNsPayloadDecoder.decode(userInfo: userInfo) else { once.finish(.noData); return true }
        let operation = Task { @MainActor in
            guard let value = center() else { once.finish(.failed); return }
            let result = await value.receive(payload: payload, source: .background)
            switch result {
            case .newData: once.finish(.newData)
            case .noData, .rejected: once.finish(.noData)
            case .deferred: once.finish(.failed)
            }
        }
        Task { @MainActor in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            once.finish(.failed); operation.cancel()
            center()?.expireWake(eventID: payload.eventID)
        }
        return true
    }
    /// The existing delegate immediately answers [] when true, avoiding a
    /// duplicate system banner alongside the native release-notes sheet.
    static func foreground(userInfo: [AnyHashable: Any], center: @escaping Center) -> Bool {
        guard userInfo["floe"] != nil else { return false }
        guard let payload = try? APNsPayloadDecoder.decode(userInfo: userInfo) else { return true }
        Task { @MainActor in _ = await center()?.receive(payload: payload, source: .foreground) }
        return true
    }
    static func tapped(userInfo: [AnyHashable: Any], center: @escaping Center,
                       completion: @escaping () -> Void) -> Bool {
        guard userInfo["floe"] != nil else { return false }
        let once = NotificationResponseCompletion(completion)
        guard let payload = try? APNsPayloadDecoder.decode(userInfo: userInfo) else { _ = once.finish(); return true }
        _ = once.finish()
        Task { @MainActor in
            if payload.kind == .release { await center()?.openRelease(payload: payload) }
        }
        return true
    }
}

private nonisolated final class APNsFetchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((UIBackgroundFetchResult) -> Void)?
    init(_ callback: @escaping (UIBackgroundFetchResult) -> Void) { self.callback = callback }
    func finish(_ result: UIBackgroundFetchResult) {
        lock.lock(); let completion = callback; callback = nil; lock.unlock()
        completion?(result)
    }
}
#endif
