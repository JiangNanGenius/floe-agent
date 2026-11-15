// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameSpriteCore

@Suite("Bounded PNG codec")
struct SpritePNGTests {
    @Test("Exact RGBA roundtrip preserves transparent hidden color")
    func exactRoundtrip() throws {
        var image = try SpriteTestSupport.image(width: 7, height: 3)
        let colors: [SpriteRGBA] = [
            SpriteRGBA(red: 200, green: 100, blue: 50, alpha: 0),
            SpriteRGBA(red: 1, green: 2, blue: 3, alpha: 255),
            SpriteRGBA(red: 250, green: 128, blue: 64, alpha: 128),
            SpriteRGBA(red: 0, green: 0, blue: 0, alpha: 255),
            SpriteRGBA(red: 255, green: 255, blue: 255, alpha: 0),
            SpriteRGBA(red: 17, green: 34, blue: 51, alpha: 1)
        ]
        var index = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                image.setColor(colors[index % colors.count], x: x, y: y)
                index += 1
            }
        }

        let data = try SpritePNG.encode(image, verify: false)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let decoded = try SpritePNG.decode(data)
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
        #expect(decoded.pixels == image.pixels)
        #expect(decoded == image)
    }

    @Test("Non-square opaque sheet roundtrips")
    func nonSquareRoundtrip() throws {
        let image = try SpriteTestSupport.image(width: 31, height: 9,
                                                fill: SpriteRGBA(red: 12, green: 34, blue: 56, alpha: 255))
        let data = try SpritePNG.encode(image)
        let decoded = try SpritePNG.decode(data)
        #expect(decoded == image)
    }

    @Test("Empty data and truncated PNG are rejected")
    func invalidData() throws {
        do {
            _ = try SpritePNG.decode(Data())
            Issue.record("Empty data must not decode")
        } catch let error as SpritePNGError {
            #expect(error == .emptyData)
        }

        do {
            _ = try SpritePNG.decode(Data("not a PNG".utf8))
            Issue.record("Non-PNG bytes must not decode")
        } catch let error as SpritePNGError {
            #expect(error == .invalidPNG)
        }

        let original = try SpritePNG.encode(SpriteTestSupport.image(width: 16, height: 16,
                                                                    fill: .white))
        let truncated = SpriteTestSupport.truncated(original)
        do {
            _ = try SpritePNG.decode(truncated)
            Issue.record("Truncated PNG must not decode")
        } catch let error as SpritePNGError {
            #expect(error == .truncated || error == .invalidPNG)
        }
    }

    @Test("Dimension, pixel-count and encoded-byte limits reject before decode")
    func limits() throws {
        let data = try SpritePNG.encode(SpriteTestSupport.image(width: 8, height: 8, fill: .white))
        do {
            _ = try SpritePNG.decode(data, limits: SpritePNGLimits(maximumDimension: 4))
            Issue.record("Dimension limit must reject an 8 × 8 image")
        } catch let error as SpritePNGError {
            if case .dimensionsExceeded(let width, let height) = error {
                #expect(width == 8)
                #expect(height == 8)
            } else {
                Issue.record("Expected dimensionsExceeded, got \(error)")
            }
        }
        do {
            _ = try SpritePNG.decode(data, limits: SpritePNGLimits(maximumPixelCount: 16))
            Issue.record("Pixel limit must reject a 64-pixel image")
        } catch let error as SpritePNGError {
            #expect(error == .dimensionsExceeded(width: 8, height: 8))
        }
        do {
            _ = try SpritePNG.decode(data, limits: SpritePNGLimits(maximumEncodedBytes: 16))
            Issue.record("Encoded-byte limit must reject the PNG")
        } catch let error as SpritePNGError {
            if case .encodedBytesExceeded = error { } else {
                Issue.record("Expected encodedBytesExceeded, got \(error)")
            }
        }
    }

    @Test("Encoding an empty or malformed pixel model fails visibly")
    func malformedPixelModel() throws {
        do {
            _ = try SpritePixelImage(width: 0, height: 10)
            Issue.record("Zero-width image must not allocate")
        } catch let error as SpritePixelError {
            #expect(error == .invalidDimensions(width: 0, height: 10))
        }
        do {
            _ = try SpritePixelImage(width: 2, height: 2, rgba: [1, 2, 3])
            Issue.record("Mismatched pixel buffer must not allocate")
        } catch let error as SpritePixelError {
            #expect(error == .pixelCountMismatch(expected: 16, actual: 3))
        }
    }
}
