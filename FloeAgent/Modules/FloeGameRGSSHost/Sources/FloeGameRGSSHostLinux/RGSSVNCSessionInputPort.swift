// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameWebKit
import FloeGameRGSSHostCore
import FloeVNC

/// Existing `VNCSession` adapted to held-key phases. The desktop viewer and
/// game input share one owned display client; this port only sends the game's
/// physical keys and releases exactly the keys it pressed.
public final class RGSSVNCSessionInputPort: RGSSGuestPhysicalInputPort, @unchecked Sendable {
    private let sessionProvider: @Sendable () async -> VNCSession?
    private let lock = NSLock()
    private struct HeldKey {
        let key: GameKeyboardKey
        let session: VNCSession
    }
    private var pressed: [HeldKey] = []

    public init(session: VNCSession) {
        self.sessionProvider = { session }
    }

    /// Stable port for a retained display owner. The provider resolves the
    /// owner's current VNCSession after a viewer reconnect; the running job's
    /// input session keeps this same port object.
    public init(sessionProvider: @escaping @Sendable () async -> VNCSession?) {
        self.sessionProvider = sessionProvider
    }

    public func keyDown(_ key: GameKeyboardKey) async throws {
        let code = key.x11KeySym
        guard code != 0 else {
            throw RGSSGuestRunError.inputUnavailable("key \(key.rawValue) has no X11 keysym")
        }
        guard let session = await sessionProvider(), session.isConnected else {
            throw RGSSGuestRunError.inputUnavailable("the local display is not connected")
        }
        try lock.withLock {
            guard !pressed.contains(where: { $0.key == key }) else { return }
            guard session.sendKeyPhase(code, pressed: true) else {
                throw RGSSGuestRunError.inputUnavailable("the local display is not connected")
            }
            pressed.append(HeldKey(key: key, session: session))
        }
    }

    public func keyUp(_ key: GameKeyboardKey) async throws {
        lock.withLock {
            guard let index = pressed.firstIndex(where: { $0.key == key }) else { return }
            let held = pressed.remove(at: index)
            // Reconnect may have installed a different current VNCSession.
            // A release belongs only to the session that received this down.
            held.session.sendKeyPhase(key.x11KeySym, pressed: false)
        }
    }

    /// Releases only keys this port still believes it pressed. Other viewers
    /// and the terminal on the same display are untouched.
    public func releaseAll() async {
        lock.withLock {
            let keys = pressed
            pressed.removeAll()
            for held in keys.reversed() {
                held.session.sendKeyPhase(held.key.x11KeySym, pressed: false)
            }
        }
    }
}
