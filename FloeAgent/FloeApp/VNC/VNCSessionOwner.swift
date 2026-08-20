// FloeApp — VNC session owner (app-internal).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns the LoopbackSSHForwarder + VNCSession for one VNC session, OUTSIDE
// the view lifecycle. VNC always connects through the SSH loopback
// forwarder (never a public listener). Tracks FPS and owns the emergency
// stop path. Views render snapshots; they never hold these handles.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence
import FloeSSH
import FloeVNC

/// Owns one VNC-over-SSH session's live handles and FPS window.
@MainActor
final class VNCSessionOwner {
    let sessionID: UUID
    let hostID: UUID

    private(set) var forwarder: LoopbackSSHForwarder?
    private(set) var session: VNCSession?
    private let registry: any RemoteSessionRegistry
    private var stateObservationInstalled = false

    /// Current measured FPS from the VNC session.
    private(set) var framesPerSecond: Double = 0
    /// Latest VNC connection state for the status bar.
    private(set) var connectionState: VNCSessionState = .disconnected

    var onStateChange: (() -> Void)?

    init(sessionID: UUID, hostID: UUID, registry: any RemoteSessionRegistry) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.registry = registry
    }

    /// Installs the connected forwarder + VNC session and starts observing.
    func attach(forwarder: LoopbackSSHForwarder, session: VNCSession) {
        self.forwarder = forwarder
        self.session = session
        installStateObservation()
    }

    private func installStateObservation() {
        guard !stateObservationInstalled, let session else { return }
        stateObservationInstalled = true
        session.onStateChange { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionState = state
                self.framesPerSecond = session.measuredFramesPerSecond
                self.onStateChange?()
            }
        }
    }

    /// Refreshes the FPS reading (called by the view's status timer).
    func refreshFPS() {
        framesPerSecond = session?.measuredFramesPerSecond ?? 0
    }

    func send(_ action: VNCAction) async throws {
        try action.validate()
        guard let session else { return }
        apply(action, to: session)
    }

    private func apply(_ action: VNCAction, to session: VNCSession) {
        switch action {
        case .click(let point, _):
            let x = UInt16(clamping: point.x)
            let y = UInt16(clamping: point.y)
            session.mouseMove(x: x, y: y)
            session.mouseDown(x: x, y: y)
            session.mouseUp(x: x, y: y)
        case .typeText(let text):
            session.send(text: text)
        default:
            // Drag/scroll/key/wait/finish are exercised by the agent loop,
            // not the manual viewer; the viewer handles its own gestures.
            break
        }
    }

    func suspend() async {
        try? await registry.updateState(id: sessionID, state: .suspended, lastHeartbeatAt: Date())
    }

    func disconnect() async {
        session?.disconnect()
        await forwarder?.close()
        session = nil
        forwarder = nil
        try? await registry.updateState(id: sessionID, state: .disconnected, lastHeartbeatAt: Date())
    }

    /// Emergency stop: immediately tears down the session and forwarder.
    /// Persistent and always reachable during a VNC session.
    func emergencyStop() async {
        await disconnect()
    }
}
#endif
