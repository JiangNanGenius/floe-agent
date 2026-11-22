// FloeMacTerminal — AppKit bridge for SwiftTerm's LocalProcessTerminalView.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import SwiftTerm

/// Hosts the session's `LocalProcessTerminalView`.
///
/// The surface only attaches/detaches the terminal view owned by
/// `MacTerminalSession`; teardown detaches without killing the child, so a
/// rebuilt view resumes the same running session (same scrollback, same PTY).
///
/// Public so host features (the task terminal inspector) can embed the same
/// surface. This exposes display/attach only: user input still goes through
/// the on-screen terminal view, so no model-authored code path reaches the
/// PTY.
public struct MacTerminalSurface: NSViewRepresentable {
    @ObservedObject public var session: MacTerminalSession

    public init(session: MacTerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        return host
    }

    public func updateNSView(_ host: NSView, context: Context) {
        guard let terminal = session.terminalView else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if terminal.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = host.bounds
            terminal.autoresizingMask = [.width, .height]
            host.addSubview(terminal)
        }
    }

    public static func dismantleNSView(_ host: NSView, coordinator: ()) {
        // Detach only: closing the session is the session owner's decision
        // (explicit close button, or its deinit backstop), never an implicit
        // side effect of SwiftUI view recycling.
        host.subviews.forEach { $0.removeFromSuperview() }
    }
}
