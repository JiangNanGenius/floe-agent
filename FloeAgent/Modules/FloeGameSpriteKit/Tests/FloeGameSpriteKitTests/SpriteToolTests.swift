// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameSpriteCore

@Suite("Pixel tools, strokes and transforms")
struct SpriteToolTests {
    @Test("Brush and stroke are clipped to the selected frame")
    func brushBoundary() throws {
        let clip = SpritePixelRect(x: 0, y: 0, width: 3, height: 3)
        var image = try SpriteTestSupport.image(width: 8, height: 8)
        let color = SpriteRGBA(red: 250, green: 10, blue: 20, alpha: 255)
        let changed = image.drawBrush(at: SpritePixelPoint(x: 0, y: 0),
                                      color: color, brushSize: 3, clip: clip)
        #expect(changed == 4)
        #expect(image.color(x: 0, y: 0) == color)
        #expect(image.color(x: 1, y: 1) == color)
        #expect(image.color(x: 2, y: 0)?.isTransparent == true)
        #expect(image.color(x: 0, y: 2)?.isTransparent == true)
        #expect(image.color(x: 4, y: 4)?.isTransparent == true)

        let strokeChanged = image.drawStroke(from: SpritePixelPoint(x: 0, y: 0),
                                             to: SpritePixelPoint(x: 5, y: 0),
                                             color: color, brushSize: 1, clip: clip)
        #expect(strokeChanged == 1)
        #expect(image.color(x: 2, y: 0) == color)
        #expect(image.color(x: 3, y: 0)?.isTransparent == true)
    }

    @Test("Fast strokes leave no gaps")
    func contiguousStroke() throws {
        var image = try SpriteTestSupport.image(width: 12, height: 4)
        let color = SpriteRGBA(red: 10, green: 200, blue: 30, alpha: 255)
        image.drawStroke(from: SpritePixelPoint(x: 0, y: 0),
                         to: SpritePixelPoint(x: 11, y: 3),
                         color: color, brushSize: 1)
        var previous: SpritePixelPoint?
        var colored = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image.color(x: x, y: y) == color {
                colored += 1
                if let previous {
                    let dx = abs(x - previous.x)
                    let dy = abs(y - previous.y)
                    #expect(dx <= 1 && dy <= 1)
                }
                previous = SpritePixelPoint(x: x, y: y)
            }
        }
        #expect(colored == 12)
    }

    @Test("Flood fill stays inside the frame and stops at a barrier")
    func fillBoundary() throws {
        var image = try SpriteTestSupport.image(width: 8, height: 8)
        let clip = SpritePixelRect(x: 0, y: 0, width: 4, height: 4)
        let white = SpriteRGBA.white
        let barrier = SpriteRGBA(red: 0, green: 0, blue: 255, alpha: 255)
        let green = SpriteRGBA(red: 0, green: 200, blue: 0, alpha: 255)
        for y in 0..<4 {
            for x in 0..<4 {
                image.setColor(white, x: x, y: y)
            }
        }
        for y in 0..<4 { image.setColor(barrier, x: 2, y: y) }

        let changed = image.floodFill(from: SpritePixelPoint(x: 0, y: 0),
                                      color: green, clip: clip)
        #expect(changed == 8)
        #expect(image.color(x: 0, y: 0) == green)
        #expect(image.color(x: 1, y: 3) == green)
        #expect(image.color(x: 2, y: 0) == barrier)
        #expect(image.color(x: 3, y: 0) == white)
        #expect(image.color(x: 4, y: 0)?.isTransparent == true)
        #expect(image.color(x: 0, y: 4)?.isTransparent == true)
    }

    @Test("Eraser clears pixels and eyedropper reads exact RGBA")
    func eraserAndEyedropper() throws {
        let color = SpriteRGBA(red: 12, green: 34, blue: 56, alpha: 200)
        var image = try SpriteTestSupport.image(width: 4, height: 4, fill: color)
        image.drawBrush(at: SpritePixelPoint(x: 1, y: 1), color: .clear, brushSize: 2)
        #expect(image.color(x: 1, y: 1) == .clear)
        #expect(image.color(x: 2, y: 2) == .clear)
        #expect(image.color(x: 0, y: 0) == color)
        #expect(image.color(x: 3, y: 3) == color)
    }

    @Test("SpriteStroke applies one bounded gesture to fresh bytes")
    @MainActor
    func strokeApplication() throws {
        var image = try SpriteTestSupport.image(width: 10, height: 10)
        let clip = SpritePixelRect(x: 0, y: 0, width: 5, height: 5)
        let stroke = SpriteStroke(tool: .brush,
                                  color: SpriteRGBA(red: 240, green: 30, blue: 50, alpha: 255),
                                  brushSize: 2, clip: clip, frameIndex: 0,
                                  originalSize: image.size,
                                  seed: SpritePixelPoint(x: 1, y: 1), image: image)
        stroke.append(SpritePixelPoint(x: 3, y: 2))
        let changed = stroke.apply(to: &image)
        #expect(changed > 0)
        #expect(image.color(x: 1, y: 1) == stroke.color)
        #expect(image.color(x: 3, y: 2) == stroke.color)
        #expect(image.color(x: 6, y: 6)?.isTransparent == true)
        #expect(stroke.points.count == 2)
    }

    @Test("Flip and 90-degree rotation keep orientation correct")
    func transforms() throws {
        var image = try SpriteTestSupport.image(width: 3, height: 2)
        let red = SpriteRGBA(red: 255, green: 0, blue: 0, alpha: 255)
        let green = SpriteRGBA(red: 0, green: 255, blue: 0, alpha: 255)
        let blue = SpriteRGBA(red: 0, green: 0, blue: 255, alpha: 255)
        image.setColor(red, x: 0, y: 0)
        image.setColor(green, x: 2, y: 0)
        image.setColor(blue, x: 0, y: 1)

        let flipped = image.flippedHorizontally()
        #expect(flipped.color(x: 2, y: 0) == red)
        #expect(flipped.color(x: 0, y: 0) == green)
        #expect(flipped.color(x: 2, y: 1) == blue)

        let vertical = image.flippedVertically()
        #expect(vertical.color(x: 0, y: 1) == red)
        #expect(vertical.color(x: 0, y: 0) == blue)

        let clockwise = image.rotated90Clockwise()
        #expect(clockwise.width == 2)
        #expect(clockwise.height == 3)
        #expect(clockwise.color(x: 1, y: 0) == red)
        #expect(clockwise.color(x: 1, y: 2) == green)
        #expect(clockwise.color(x: 0, y: 0) == blue)

        let counter = image.rotated90Counterclockwise()
        #expect(counter.width == 2)
        #expect(counter.height == 3)
        #expect(counter.color(x: 0, y: 2) == red)
        #expect(counter.color(x: 0, y: 0) == green)
        #expect(counter.color(x: 1, y: 2) == blue)
    }
}
