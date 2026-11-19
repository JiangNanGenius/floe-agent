// SPDX-License-Identifier: MPL-2.0
//
// Embedded native remote desktop surface. Wraps RoyalVNCKit's macOS
// framebuffer view directly, so rendering, pointer, and keyboard input are
// the framework's real implementations against the live framebuffer — not a
// thumbnail, a web view, or the system screen-sharing UI.

import AppKit
import RoyalVNCKit
import SwiftUI

struct MacVNCRemoteSurface: NSViewRepresentable {
    let surface: MacVNCDisplaySurface

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VNCCAFramebufferView {
        // The framework view becomes the connection's delegate for rendering
        // and input, and forwards state/credential callbacks to our session.
        VNCCAFramebufferView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1),
            framebuffer: surface.framebuffer,
            connection: surface.connection,
            connectionDelegate: surface.session
        )
    }

    func updateNSView(_ nsView: VNCCAFramebufferView, context: Context) {}

    static func dismantleNSView(_ nsView: VNCCAFramebufferView, coordinator: Coordinator) {
        // When SwiftUI drops the surface (close/resume), hand delegate
        // ownership back to the session so state tracking stays live until
        // the connection is torn down.
        nsView.connection?.delegate = nsView.delegate
    }

    final class Coordinator {}
}
