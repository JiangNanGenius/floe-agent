// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import WebKit

#if os(macOS)
public struct GamePlayerView: NSViewRepresentable {
    public let player: GameWebPlayer
    public init(player: GameWebPlayer) { self.player = player }
    public func makeNSView(context: Context) -> WKWebView { player.webView }
    public func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
public struct GamePlayerView: UIViewRepresentable {
    public let player: GameWebPlayer
    private let arrangingControls: Bool

    public init(player: GameWebPlayer, arrangingControls: Bool = false) {
        self.player = player
        self.arrangingControls = arrangingControls
    }
    public func makeUIView(context: Context) -> WKWebView { player.webView }
    public func updateUIView(_ view: WKWebView, context: Context) {
        if arrangingControls { view.scrollView.stopScrollingAndZooming() }
    }
}
#endif
