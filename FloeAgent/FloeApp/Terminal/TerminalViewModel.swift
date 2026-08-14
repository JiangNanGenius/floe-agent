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

    /// The terminal output, decoded for display.
    @Published private(set) var outputText: String = ""

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
        let data = center.terminalOutput(for: sessionID)
        outputText = String(decoding: data, as: UTF8.self)
    }

    func send(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        try? await center.send(data, to: sessionID)
        await refresh()
    }

    func resize(columns: Int, rows: Int) async {
        try? await center.resize(sessionID: sessionID, columns: columns, rows: rows)
    }

    func disconnect() async {
        await center.disconnectTerminal(sessionID: sessionID)
    }
}
#endif
