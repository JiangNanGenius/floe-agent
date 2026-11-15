// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit

/// Service-owned observation, independent of whether the game view is visible.
/// Tokens are immutable after construction; Foundation removal is thread-safe.
final class GameApplicationActivityObserver: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    private final class DeliveryEpoch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func advance() -> UInt64 { lock.withLock { value &+= 1; return value } }
        func contains(_ token: UInt64) -> Bool { lock.withLock { value == token } }
    }

    @MainActor init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        let center = NotificationCenter.default
        let epoch = DeliveryEpoch()
        tokens = [
            center.addObserver(forName: UIApplication.willResignActiveNotification,
                               object: nil, queue: .main) { _ in
                let token = epoch.advance()
                Task { @MainActor in
                    guard epoch.contains(token) else { return }
                    onChange(false)
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { _ in
                let token = epoch.advance()
                Task { @MainActor in
                    guard epoch.contains(token) else { return }
                    onChange(true)
                }
            }
        ]
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
#endif
