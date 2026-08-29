// FloeApp — VNC session owner (app-internal).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns an optional LoopbackSSHForwarder + VNCSession for one VNC session,
// OUTSIDE the view lifecycle. Direct VNC has no forwarder; tunneled VNC
// retains the verified SSH forwarder here.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSSH
import FloeVNC

/// Owns one VNC-over-SSH session's live handles and FPS window.
@MainActor
final class VNCSessionOwner {
    let sessionID: UUID
    let hostID: UUID
    let endpointHost: String
    let endpointPort: Int

    private(set) var forwarder: LoopbackSSHForwarder?
    private(set) var session: VNCSession?
    private let registry: any RemoteSessionRegistry
    private var stateObservationInstalled = false

    /// Current measured FPS from the VNC session.
    private(set) var framesPerSecond: Double = 0
    /// Latest VNC connection state for the status bar.
    private(set) var connectionState: VNCSessionState = .disconnected

    var onStateChange: (() -> Void)?

    init(
        sessionID: UUID,
        hostID: UUID,
        endpointHost: String,
        endpointPort: Int,
        registry: any RemoteSessionRegistry
    ) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
        self.registry = registry
    }

    /// Installs the connected forwarder + VNC session and starts observing.
    func attach(forwarder: LoopbackSSHForwarder, session: VNCSession) {
        self.forwarder = forwarder
        self.session = session
        installStateObservation()
    }

    /// Installs a direct VNC session without manufacturing an SSH tunnel.
    func attach(session: VNCSession) {
        self.forwarder = nil
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
                let durableState: RemoteSessionRecord.State
                let heartbeat: Date?
                switch state {
                case .connecting:
                    durableState = .connecting
                    heartbeat = nil
                case .connected:
                    durableState = .connected
                    heartbeat = Date()
                case .disconnected, .failed:
                    durableState = .disconnected
                    heartbeat = Date()
                }
                try? await self.registry.updateState(
                    id: self.sessionID,
                    state: durableState,
                    lastHeartbeatAt: heartbeat
                )
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
        guard let session else {
            throw VNCConnectionFailure(
                category: .configurationMissing,
                stage: .configuration,
                retryable: true,
                host: endpointHost,
                port: endpointPort,
                message: "The VNC session handle is no longer available. Reconnect before sending input."
            )
        }
        switch connectionState {
        case .connected:
            break
        case .failed(let failure):
            throw failure
        case .connecting:
            throw VNCConnectionFailure(
                category: .handshakeFailed,
                stage: .handshake,
                retryable: true,
                host: endpointHost,
                port: endpointPort,
                message: "The VNC session is still connecting; input was not dispatched."
            )
        case .disconnected:
            throw VNCConnectionFailure(
                category: .handshakeFailed,
                stage: .transport,
                retryable: true,
                host: endpointHost,
                port: endpointPort,
                message: "The VNC session is disconnected; input was not dispatched."
            )
        }
        try apply(action, to: session)
    }

    private func apply(_ action: VNCAction, to session: VNCSession) throws {
        switch action {
        case .click(let point, let button):
            guard button == .left else {
                throw FloeError.invalidConfiguration(
                    "The embedded VNC client currently supports left-button manual clicks only."
                )
            }
            let x = UInt16(clamping: point.x)
            let y = UInt16(clamping: point.y)
            session.mouseMove(x: x, y: y)
            session.mouseDown(x: x, y: y)
            session.mouseUp(x: x, y: y)
        case .typeText(let text):
            session.send(text: text)
        default:
            // Agent tools dispatch their richer actions directly after a
            // fresh screenshot check. Never report an unsupported manual
            // action as successful merely because an owner object exists.
            throw FloeError.invalidConfiguration(
                "This VNC action must be sent through the evidence-backed agent tool."
            )
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
