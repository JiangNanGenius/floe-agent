// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Testing
import FloeGameSpriteCore
@testable import FloeGameSpriteUI

struct SpriteCanvasFocusTests {
    @Test("Selected sprite frames stay fully visible and drawable", arguments: [0, 1, 2])
    func selectedFrame(index: Int) throws {
        let frames = [SpritePixelRect(x: 0, y: 0, width: 48, height: 48),
                      SpritePixelRect(x: 144, y: 96, width: 48, height: 48),
                      SpritePixelRect(x: 528, y: 336, width: 48, height: 48)]
        let view = CGSize(width: 820, height: 700)
        let transform = SpriteCanvasTransform(viewSize: view,
            imageSize: SpritePixelSize(width: 576, height: 384), zoom: 1, pan: .zero)
        let focused = transform.focusing(frames[index])
        #expect(focused.zoom > transform.zoom)
        #expect(CGRect(origin: .zero, size: view).contains(focused.screenRect(frames[index])))
        let center = try #require(focused.pixelPoint(from: CGPoint(x: view.width / 2, y: view.height / 2)))
        #expect(frames[index].contains(center))
    }

    @Test("Focus remains bounded for a one-pixel frame in a large sheet")
    func maximumZoom() {
        let transform = SpriteCanvasTransform(viewSize: CGSize(width: 320, height: 400),
            imageSize: SpritePixelSize(width: 8_192, height: 2_048), zoom: 1, pan: .zero)
        let frame = SpritePixelRect(x: 0, y: 0, width: 1, height: 1)
        let focused = transform.focusing(frame)
        #expect(focused.zoom == SpriteCanvasTransform.maximumZoom)
        #expect(CGRect(origin: .zero, size: transform.viewSize).intersects(focused.screenRect(frame)))
        #expect(focused.pan.width.isFinite && focused.pan.height.isFinite)
    }
}
