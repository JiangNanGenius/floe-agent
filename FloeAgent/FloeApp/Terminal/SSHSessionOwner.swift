// FloeApp — SSH terminal session owner (app-internal).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns the Citadel SSHSessionHandle + PTYSessionHandle for one terminal
// session, OUTSIDE the view lifecycle. Runs the output pump, accepts
// paste/resize, and writes state transitions into RemoteSessionRegistry so
// a backgrounded/relaunched app reports connected/suspended/unknown
// honestly. Views render snapshots; they never hold these handles.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence
import FloeSSH

/// Owns one SSH terminal session's live handles and output pump.
@MainActor
final class SSHSessionOwner {
    let sessionID: UUID
    let hostID: UUID

    private(set) var handle: SSHSessionHandle?
    private(set) var pty: PTYSessionHandle?
    private var pumpTask: Task<Void, Never>?
    private let registry: any RemoteSessionRegistry

    /// Terminal output buffer (bounded; the view renders the tail).
    private(set) var output = Data()
    private let maxOutputBytes = 256 * 1024
    /// Called on the main actor when new output arrives.
    var onOutput: (() -> Void)?
    /// Called on the main actor when the connection drops.
    var onDisconnect: (() -> Void)?

    init(sessionID: UUID, hostID: UUID, registry: any RemoteSessionRegistry) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.registry = registry
    }

    /// Installs the connected handles and starts the output pump.
    func attach(handle: SSHSessionHandle, pty: PTYSessionHandle) {
        self.handle = handle
        self.pty = pty
        startPump()
    }

    private func startPump() {
        guard let pty else { return }
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in pty.output {
                    if Task.isCancelled { break }
                    await self.append(chunk)
                }
            } catch {
                // Stream threw; the disconnect handler marks honest state.
            }
            await self.handlePumpEnded()
        }
    }

    private func append(_ chunk: Data) {
        output.append(chunk)
        if output.count > maxOutputBytes {
            output = output.suffix(maxOutputBytes)
        }
        onOutput?()
    }

    private func handlePumpEnded() async {
        // The PTY stream ended. If the app didn't drive this (suspend/
        // disconnect), the socket fate is unknown — never report paused.
        await markState(.unknown)
        onDisconnect?()
    }

    func send(_ data: Data) async throws {
        try await pty?.write(data)
    }

    func resize(columns: Int, rows: Int) async throws {
        try await pty?.resize(columns: columns, rows: rows)
    }

    /// Marks the session suspended (app backgrounding). The handle stays
    /// alive; reconciliation on resume re-marks honestly.
    func suspend() async {
        await markState(.suspended)
    }

    func disconnect() async {
        pumpTask?.cancel()
        pumpTask = nil
        await pty?.close()
        await handle?.close()
        pty = nil
        handle = nil
        await markState(.disconnected)
    }

    private func markState(_ state: RemoteSessionRecord.State) async {
        try? await registry.updateState(
            id: sessionID,
            state: state,
            lastHeartbeatAt: Date()
        )
    }
}
#endif
