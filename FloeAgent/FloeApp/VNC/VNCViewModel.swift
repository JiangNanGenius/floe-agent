// FloeApp — VNC view model (thin).
//
// SPDX-License-Identifier: MPL-2.0
//
// Thin binding between the VNC viewer and RemoteSessionCenter. Holds only
// presentation state (FPS, status); the session/forwarder handles stay in
// the center's VNCSessionOwner.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeVNC

/// View model for the VNC screen.
@MainActor
final class VNCViewModel: ObservableObject {

    @Published private(set) var framesPerSecond: Double = 0

    let sessionID: UUID
    let center: RemoteSessionCenter

    init(sessionID: UUID, center: RemoteSessionCenter) {
        self.sessionID = sessionID
        self.center = center
    }

    var snapshot: RemoteSessionSnapshot? {
        center.sessions[sessionID]
    }

    /// The live VNC session for the viewer (owned by the center).
    var session: VNCSession? {
        center.vncSession(for: sessionID)
    }

    func refreshFPS() {
        framesPerSecond = center.vncFPS(for: sessionID)
    }

    func disconnect() async {
        await center.disconnectVNC(sessionID: sessionID)
    }

    /// Emergency stop: always reachable, immediately tears down the session.
    func emergencyStop() async {
        await center.emergencyStop(sessionID: sessionID)
    }
}
#endif
