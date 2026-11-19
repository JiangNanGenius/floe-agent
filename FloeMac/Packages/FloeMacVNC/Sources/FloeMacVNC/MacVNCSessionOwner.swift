// SPDX-License-Identifier: MPL-2.0
//
// Toolbox-facing lifecycle owner for one embedded VNC remote desktop.
//
// Lifecycle contract:
// - `connect(using:)` opens a connection manually; nothing connects on its own.
// - `close()` asks the active connection to end (user disconnect). The owner
//   enters `.closing` and the password is dropped immediately; the transport
//   settles asynchronously.
// - `resume()` resets a closed/failed owner back to `idle` so a new manual
//   connection can be opened with the same form state.
// - `drain()` is the externally awaitable teardown for window close or OTA:
//   it disconnects anything in flight and returns only after RoyalVNCKit has
//   fully settled. It returns `false` if the bounded timeout elapsed before
//   the real disconnect completed. It is idempotent.
//
// Connect stays disabled until the previous connection actually settles
// (`isSettled`), so rapid disconnect/reconnect cannot orphan an earlier
// transport.

import Combine
import Foundation

@MainActor
public final class MacVNCSessionOwner: ObservableObject {
    @Published public private(set) var state: MacVNCConnectionState = .idle
    @Published public private(set) var framesPerSecond: Double = 0
    @Published public private(set) var displaySurface: MacVNCDisplaySurface?
    /// No session exists, or the current session has reached a terminal
    /// state. `canConnect` stays false until this is true.
    @Published public private(set) var isSettled: Bool = true

    /// Last manually-entered configuration. The password is cleared on close
    /// and drain; the host/port remain in memory only so the form can be
    /// prefilled on resume.
    public private(set) var lastConfiguration: MacVNCConfiguration?

    private var session: MacVNCSession?
    private var drained = false

    public init() {}

    public var canConnect: Bool {
        guard isSettled, !drained else { return false }
        switch state {
        case .idle, .closed, .failed: return true
        case .connecting, .connected, .closing: return false
        }
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    public var lastFailure: MacVNCConnectionFailure? {
        if case .failed(let failure) = state { return failure }
        return nil
    }

    /// Manual open. Only a person clicking Connect in the tool view reaches
    /// this entry point; nothing in this package initiates remote access.
    public func connect(using configuration: MacVNCConfiguration) throws {
        guard !drained else { throw MacVNCValidationError.ownerDrained }
        guard canConnect else { throw MacVNCValidationError.connectionActive }
        let validated = try configuration.validated()
        let newSession = MacVNCSession(configuration: validated)
        wire(newSession)
        session = newSession
        lastConfiguration = validated
        displaySurface = nil
        framesPerSecond = 0
        isSettled = false
        state = .connecting
        newSession.connect()
    }

    /// User disconnect. Requests teardown and drops the password; the owner
    /// stays `.closing` (not resumable, Connect disabled) until the transport
    /// settles. Use `drain()` when the caller must await the settle.
    public func close() {
        switch state {
        case .connecting, .connected:
            state = .closing
            session?.disconnect()
        case .closing:
            session?.disconnect()
        case .idle, .closed, .failed:
            break
        }
        clearSecrets()
    }

    /// Reset a terminal owner for a new manual connection.
    public func resume() {
        drained = false
        switch state {
        case .closed, .failed:
            state = .idle
            displaySurface = nil
            framesPerSecond = 0
        case .idle, .connecting, .connected, .closing:
            break
        }
    }

    /// Awaitable teardown for window close and OTA. Fences admission
    /// synchronously, disconnects any active session, and waits for the
    /// transport to settle. Returns `false` only if the bounded timeout
    /// elapsed before the real disconnect completed.
    @discardableResult
    public func drain() async -> Bool {
        drained = true
        close()
        guard let current = session else { return true }
        let deadline = ContinuousClock.now + .seconds(8)
        while !current.hasTerminated {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if session === current { finish(.closed) }
        return true
    }

    deinit {
        session?.disconnect()
    }

    // MARK: - Secrets

    /// Keep the endpoint for form prefill but never retain the password
    /// once the person closes or the session is drained.
    private func clearSecrets() {
        guard var config = lastConfiguration, config.password != nil else { return }
        config.password = nil
        lastConfiguration = config
    }

    private func finish(_ terminalState: MacVNCConnectionState) {
        state = terminalState
        session = nil
        displaySurface = nil
        framesPerSecond = 0
        isSettled = true
        clearSecrets()
    }

    // MARK: - Wiring

    private func wire(_ newSession: MacVNCSession) {
        newSession.onState = { [weak self, weak newSession] newState in
            guard let self, let newSession, self.session === newSession else { return }
            switch (self.state, newState) {
            case (.closing, .closed), (.closing, .failed):
                // User already decided to close; late failures during
                // teardown surface as a plain close, not an alarm.
                self.finish(.closed)
            case (.closing, _):
                return
            case (.idle, _), (.closed, _), (.failed, _):
                return
            case (.connecting, .failed), (.connected, .failed):
                self.finish(newState)
            case (.connecting, .closed), (.connected, .closed):
                // Remote end closed the session without an error.
                self.finish(.closed)
            case (.connecting, .connecting), (.connected, .connected):
                break
            case (.connecting, .connected), (.connected, .connecting):
                self.state = newState
            case (.connecting, .closing), (.connected, .closing):
                // The session never emits .closing; ignore defensively.
                break
            case (.connecting, .idle), (.connected, .idle):
                // The session never returns to idle; ignore defensively.
                break
            }
        }
        newSession.onDisplayReady = { [weak self, weak newSession] surface in
            guard let self, let newSession, self.session === newSession else { return }
            guard case .connecting = self.state else { return }
            self.displaySurface = surface
            self.state = .connected
        }
        newSession.onFrameTick = { [weak self, weak newSession] in
            guard let self, let newSession, self.session === newSession else { return }
            self.framesPerSecond = newSession.measuredFramesPerSecond
        }
    }
}
