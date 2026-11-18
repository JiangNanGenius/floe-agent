import AppKit
import SwiftUI

/// Tracks the actual containing window without retaining it. Notifications
/// for another window must not stop this window's media session.
@MainActor
final class MacMediaWindowReference {
    weak var window: NSWindow?

    var captureAvailable: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized
    }

    func contains(_ notification: Notification) -> Bool {
        guard let window, let sender = notification.object as? NSWindow else { return false }
        return Self.isSameWindow(window, sender)
    }

    func shouldStop(for notification: Notification) -> Bool {
        Self.shouldStop(name: notification.name, owner: window, sender: notification.object as AnyObject?)
    }

    static func shouldStop(name: Notification.Name, owner: AnyObject?, sender: AnyObject?) -> Bool {
        guard name == NSWindow.willCloseNotification || name == NSWindow.didMiniaturizeNotification else { return false }
        return isSameWindow(owner, sender)
    }

    static func isSameWindow(_ owner: AnyObject?, _ sender: AnyObject?) -> Bool {
        guard let owner, let sender else { return false }
        return owner === sender
    }
}

struct MacMediaWindowTracker: NSViewRepresentable {
    let reference: MacMediaWindowReference

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.reference = reference
        reference.window = view.window
    }
}

@MainActor
final class WindowTrackingView: NSView {
    weak var reference: MacMediaWindowReference?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference?.window = window
    }
}
