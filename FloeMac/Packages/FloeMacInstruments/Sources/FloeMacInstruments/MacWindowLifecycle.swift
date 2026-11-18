// SPDX-License-Identifier: MPL-2.0
//
// Small AppKit bridge for window-close cleanup. SwiftUI's onDisappear is not
// guaranteed when an NSWindow is merely closed and retained by the host, so
// long-lived sources also observe the actual window close event.

import AppKit
import SwiftUI

@MainActor
struct MacWindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void
    var stopWhenInactive = false

    func makeNSView(context: Context) -> WindowCloseTrackingView {
        let view = WindowCloseTrackingView()
        view.onClose = onClose
        view.stopWhenInactive = stopWhenInactive
        return view
    }

    func updateNSView(_ nsView: WindowCloseTrackingView, context: Context) {
        nsView.onClose = onClose
        nsView.stopWhenInactive = stopWhenInactive
        nsView.refresh()
    }
}

@MainActor
final class WindowCloseTrackingView: NSView {
    var onClose: (() -> Void)?
    var stopWhenInactive = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    func refresh() {
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        if stopWhenInactive {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                   name: NSWindow.didMiniaturizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                   name: NSApplication.didResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                   name: NSApplication.didHideNotification, object: nil)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
