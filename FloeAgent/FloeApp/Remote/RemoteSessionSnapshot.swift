// FloeApp — UI-facing projection of a live remote session.
//
// SPDX-License-Identifier: MPL-2.0
//
// A value-type snapshot of one SSH/VNC session. Views render only these;
// they never hold a Citadel/RoyalVNC handle. Reconciles the durable
// remote_sessions row with the live handle and RemoteRun.derivedLifecycle
// so a backgrounded/relaunched app reports connected/suspended/unknown
// honestly.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloeSSH

/// UI-facing projection of a live SSH/VNC session.
struct RemoteSessionSnapshot: Identifiable, Hashable, Sendable {
    /// The durable remote_sessions row.
    let record: RemoteSessionRecord
    /// Derived lifecycle (connected/suspended/unknown/disconnected).
    let lifecycle: RemoteRunLifecycle
    /// Current frames-per-second (VNC only; 0 for SSH).
    let framesPerSecond: Double
    /// Whether the session currently accepts input.
    let isInteractive: Bool

    var id: UUID { record.id }
    var hostID: UUID { record.hostID }
    var kind: RemoteSessionRecord.Kind { record.kind }

    /// Maps the durable session state + heartbeat age to an honest
    /// lifecycle. An unmanaged disconnect surfaces `.unknown`, never
    /// `.paused`.
    static func derive(
        record: RemoteSessionRecord,
        framesPerSecond: Double = 0
    ) -> RemoteSessionSnapshot {
        let lifecycle: RemoteRunLifecycle
        switch record.state {
        case .connecting: lifecycle = .starting
        case .connected: lifecycle = .running
        case .suspended: lifecycle = .disconnected // resumable on resume
        case .disconnected: lifecycle = .exited
        case .unknown: lifecycle = .unknown
        }
        let isInteractive = record.state == .connected
        return RemoteSessionSnapshot(
            record: record,
            lifecycle: lifecycle,
            framesPerSecond: framesPerSecond,
            isInteractive: isInteractive
        )
    }
}
#endif
