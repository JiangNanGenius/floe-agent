// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import SwiftUI
import FloeGameCore
import FloeGameEditingCore
@testable import FloeGameSpriteUI
import FloeGameSpriteCore

@Suite("Sprite UI surface")
struct SpriteUISurfaceTests {
    @Test("The public view factory signature compiles without host-only state")
    @MainActor
    func factorySignature() {
        let factory: @MainActor (GameEditingSession, GameRelativePath) -> AnyView = { session, path in
            AnyView(GameSpriteEditorView(session: session, path: path))
        }
        _ = factory
    }

    @Test("Viewport mapping stays on integer pixel boundaries")
    func canvasTransform() {
        let transform = SpriteCanvasTransform(
            viewSize: CGSize(width: 416, height: 316),
            imageSize: SpritePixelSize(width: 16, height: 16),
            zoom: 2, pan: .zero)
        let center = CGPoint(x: transform.imageRect.midX, y: transform.imageRect.midY)
        #expect(transform.pixelPoint(from: center) == SpritePixelPoint(x: 8, y: 8))
        let topLeft = CGPoint(x: transform.imageRect.minX + 1,
                              y: transform.imageRect.minY + 1)
        #expect(transform.pixelPoint(from: topLeft) == SpritePixelPoint(x: 0, y: 0))
        let outside = CGPoint(x: transform.imageRect.minX - 1,
                              y: transform.imageRect.minY - 1)
        #expect(transform.pixelPoint(from: outside) == nil)
        let rect = transform.screenRect(SpritePixelRect(x: 2, y: 3, width: 4, height: 5))
        #expect(rect.width == 4 * transform.scale)
        #expect(rect.height == 5 * transform.scale)
    }

    @Test("Color bridge keeps exact opaque RGBA values")
    func colorBridge() {
        let rgba = SpriteRGBA(red: 12, green: 34, blue: 56, alpha: 255)
        let roundtrip = SpriteColorBridge.rgba(SpriteColorBridge.color(rgba))
        #expect(roundtrip == rgba)
    }
}
