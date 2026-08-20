// FloeApp — Terminal view model (thin).
//
// SPDX-License-Identifier: MPL-2.0
//
// Thin binding between the terminal surface and RemoteSessionCenter. Holds
// only presentation state (the rendered output tail); the session handles
// stay in the center's SSHSessionOwner.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

/// View model for the terminal surface.
@MainActor
final class TerminalViewModel: ObservableObject {

    /// Raw PTY output interpreted by SwiftTerm.
    @Published private(set) var outputData = Data()

    let sessionID: UUID
    let center: RemoteSessionCenter

    init(sessionID: UUID, center: RemoteSessionCenter) {
        self.sessionID = sessionID
        self.center = center
    }

    var snapshot: RemoteSessionSnapshot? {
        center.sessions[sessionID]
    }

    var isInteractive: Bool {
        snapshot?.isInteractive ?? false
    }

    /// Pulls the latest output from the center's owner.
    func refresh() {
        outputData = center.terminalOutput(for: sessionID)
    }

    func send(_ data: Data) async {
        try? await center.send(data, to: sessionID)
        refresh()
    }

    func resize(columns: Int, rows: Int) async {
        try? await center.resize(sessionID: sessionID, columns: columns, rows: rows)
    }

    func disconnect() async {
        await center.disconnectTerminal(sessionID: sessionID)
    }
}
#endif
