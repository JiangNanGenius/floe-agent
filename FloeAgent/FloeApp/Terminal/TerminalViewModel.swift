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
    @Published private(set) var outputEnd = 0
    @Published private(set) var error: String?
    let presentation: TerminalPresentation

    let sessionID: UUID
    let center: RemoteSessionCenter

    init(sessionID: UUID, center: RemoteSessionCenter) {
        self.sessionID = sessionID
        self.center = center
        self.presentation = center.terminalPresentation(for: sessionID) ?? TerminalPresentation()
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
        outputEnd = center.terminalOutputEnd(for: sessionID)
    }

    func send(_ data: Data) async {
        guard data.count <= 64 * 1024 else {
            error = IDELanguageRunText.t("输入过多，请分段粘贴", "Too much input; paste in smaller parts")
            return
        }
        do { try await center.send(data, to: sessionID); error = nil }
        catch { self.error = error.localizedDescription }
        refresh()
    }

    func resize(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0 else { return }
        do { try await center.resize(sessionID: sessionID, columns: columns, rows: rows) }
        catch { self.error = error.localizedDescription }
    }

    func disconnect() async {
        await center.disconnectTerminal(sessionID: sessionID)
    }
}
#endif
