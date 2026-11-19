// SPDX-License-Identifier: MPL-2.0
//
// Internal RoyalVNCKit session wrapper. One instance backs one manual
// connection attempt; the owner replaces it on every new connect(). All
// delegate callbacks are re-dispatched onto the main actor for observation.

import AppKit
import Foundation
import RoyalVNCKit

/// Rendering and input surface description for SwiftUI. Created once the
/// session has a live framebuffer; consumed by `MacVNCRemoteSurface`.
/// `@unchecked Sendable`: instances are assembled on the connection queue and
/// consumed only on the main actor; RoyalVNCKit synchronizes both types
/// internally, and the owner never forwards them elsewhere.
public struct MacVNCDisplaySurface: Identifiable, @unchecked Sendable {
    public let id: UUID
    let connection: VNCConnection
    let framebuffer: VNCFramebuffer
    let session: MacVNCSession

    init(id: UUID = UUID(), connection: VNCConnection, framebuffer: VNCFramebuffer, session: MacVNCSession) {
        self.id = id
        self.connection = connection
        self.framebuffer = framebuffer
        self.session = session
    }
}

final class MacVNCSession: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    let host: String
    let port: Int
    private let passwordWasConfigured: Bool
    private var password: String?
    let connection: VNCConnection
    private var terminated = false
    private var frameTimes: [ContinuousClock.Instant] = []

    /// Main-actor callbacks installed by the owner. Secret-free by contract.
    var onState: (@MainActor (MacVNCConnectionState) -> Void)?
    var onDisplayReady: (@MainActor (MacVNCDisplaySurface) -> Void)?
    var onFrameTick: (@MainActor () -> Void)?

    init(configuration: MacVNCConfiguration) {
        host = configuration.host
        port = configuration.port
        password = configuration.password
        passwordWasConfigured = configuration.password?.isEmpty == false
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: configuration.host,
            port: UInt16(clamping: configuration.port),
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        self.connection = connection
        super.init()
        connection.delegate = self
    }

    var hasTerminated: Bool { lock.withLock { terminated } }

    func connect() {
        connection.connect()
    }

    func disconnect() {
        lock.withLock { password = nil }
        connection.disconnect()
    }

    var measuredFramesPerSecond: Double {
        lock.withLock {
            guard frameTimes.count >= 2, let first = frameTimes.first, let last = frameTimes.last
            else { return 0 }
            let duration = first.duration(to: last)
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return seconds > 0 ? Double(frameTimes.count - 1) / seconds : 0
        }
    }

    // MARK: - VNCConnectionDelegate

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        switch connectionState.status {
        case .disconnected:
            lock.withLock {
                terminated = true
                password = nil
            }
            if let error = connectionState.error {
                emit(.failed(MacVNCConnectionFailure.normalized(
                    error,
                    host: host,
                    port: port,
                    passwordConfigured: passwordWasConfigured
                )))
            } else {
                // RoyalVNCKit can emit a second, empty disconnect after the
                // real failure; preserve the actionable failure for the UI.
                emit(.closed)
            }
        case .connecting:
            emit(.connecting)
        case .connected:
            emit(.connected)
        case .disconnecting:
            break
        }
    }

    func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        // Only password authentication is supported; the password lives in
        // memory inside the validated configuration and is never logged.
        guard !authenticationType.requiresUsername,
              authenticationType.requiresPassword,
              let password = lock.withLock({ self.password }), !password.isEmpty else {
            completion(nil)
            return
        }
        completion(VNCPasswordCredential(password: password))
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        publishSurface(framebuffer: framebuffer)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        publishSurface(framebuffer: framebuffer)
    }

    func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16, y: UInt16, width: UInt16, height: UInt16
    ) {
        _ = (x, y, width, height)
        recordFrame()
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        _ = cursor
    }

    // MARK: - Private

    private func publishSurface(framebuffer: VNCFramebuffer) {
        let surface = MacVNCDisplaySurface(connection: connection, framebuffer: framebuffer, session: self)
        Task { @MainActor in
            onDisplayReady?(surface)
        }
        recordFrame()
    }

    private func recordFrame() {
        let tick: (@MainActor () -> Void)? = lock.withLock {
            let now = ContinuousClock.now
            frameTimes.append(now)
            let cutoff = now.advanced(by: .seconds(-2))
            frameTimes.removeAll { $0 < cutoff }
            return onFrameTick
        }
        if let tick {
            Task { @MainActor in tick() }
        }
    }

    private func emit(_ state: MacVNCConnectionState) {
        let handler = lock.withLock { onState }
        if let handler {
            Task { @MainActor in handler(state) }
        }
    }

}
