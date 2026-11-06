// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MediaExchangeCore

final class SelectionCompositorTests: XCTestCase {
    private func baseImage(width: Int = 64, height: Int = 48) throws -> RGBAImage {
        try RGBAImage(width: width, height: height) { x, y in
            (UInt8((x * 3) % 256), UInt8((y * 5) % 256), UInt8((x + y) % 256), 255)
        }
    }

    private func fullFramePatch(width: Int = 64, height: Int = 48) throws -> RGBAImage {
        try RGBAImage(width: width, height: height) { x, y in
            (UInt8(255 - (x * 3) % 256), UInt8(255 - (y * 5) % 256), UInt8(255 - (x + y) % 256), 255)
        }
    }

    /// Exact regression from the strict-selection qualification:
    /// 65,009 outside pixels stay byte-identical and 527 selected pixels change.
    func testModelLikeFullFrameResultCannotChangeOutsideThinSelection() throws {
        let width = 256
        let height = 256
        let base = try RGBAImage(width: width, height: height) { x, y in
            (UInt8(x % 256), UInt8(y % 256), UInt8((x * y) % 256), 255)
        }
        let patch = try RGBAImage(width: width, height: height) { x, y in
            (UInt8((255 - x) % 256), UInt8((255 - y) % 256), UInt8((x + y) % 256), 255)
        }
        let selection = PixelRect(x: 100, y: 90, width: 31, height: 17)
        let result = try StrictSelectionCompositor.composite(
            base: base,
            patch: patch,
            mask: .rectangle(selection)
        )
        XCTAssertEqual(result.selectedPixels, 527)
        XCTAssertEqual(result.changedPixels, 527)
        XCTAssertEqual(result.outsidePixels, 65_009)
        try StrictSelectionCompositor.verifyOutsideUnchanged(
            result: result.image,
            base: base,
            mask: .rectangle(selection)
        )
        for y in 0..<height {
            for x in 0..<width {
                let inside = selection.x <= x && x < selection.maxX
                    && selection.y <= y && y < selection.maxY
                if !inside {
                    XCTAssertEqual(result.image.pixel(x: x, y: y), base.pixel(x: x, y: y), "outside \(x),\(y)")
                }
            }
        }
    }

    func testEllipseOutsideBoundingBoxIsUntouched() throws {
        let base = try baseImage()
        let patch = try fullFramePatch()
        let bounds = PixelRect(x: 8, y: 6, width: 30, height: 24)
        let result = try StrictSelectionCompositor.composite(base: base, patch: patch, mask: .ellipse(bounds))
        try StrictSelectionCompositor.verifyOutsideUnchanged(result: result.image, base: base, mask: .ellipse(bounds))
        var outsideChanged = 0
        for y in 0..<base.height {
            for x in 0..<base.width {
                let insideBounds = bounds.x <= x && x < bounds.maxX && bounds.y <= y && y < bounds.maxY
                if !insideBounds && result.image.pixel(x: x, y: y) != base.pixel(x: x, y: y) {
                    outsideChanged += 1
                }
            }
        }
        XCTAssertEqual(outsideChanged, 0)
        XCTAssertGreaterThan(result.changedPixels, 0)
    }

    func testZeroCoverageLeavesEveryByteAlone() throws {
        let base = try baseImage()
        let patch = try fullFramePatch()
        let mask = SelectionMask.coverage(
            width: base.width,
            height: base.height,
            values: [UInt8](repeating: 0, count: base.width * base.height)
        )
        let result = try StrictSelectionCompositor.composite(base: base, patch: patch, mask: mask)
        XCTAssertEqual(result.image, base)
        XCTAssertEqual(result.changedPixels, 0)
        XCTAssertEqual(result.outsidePixels, base.width * base.height)
    }

    func testRectangleOutsideCanvasAndDimensionMismatchAreRejected() throws {
        let base = try baseImage()
        let patch = try fullFramePatch()
        XCTAssertThrowsError(try StrictSelectionCompositor.composite(
            base: base,
            patch: patch,
            mask: .rectangle(PixelRect(x: 60, y: 0, width: 10, height: 10))
        ))
        XCTAssertThrowsError(try StrictSelectionCompositor.composite(
            base: base,
            patch: try RGBAImage(width: 10, height: 10, fill: 0),
            mask: .rectangle(PixelRect(x: 0, y: 0, width: 5, height: 5))
        ))
        let overflow = PixelRect(x: Int.max - 4, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(try StrictSelectionCompositor.composite(
            base: base,
            patch: patch,
            mask: .rectangle(overflow)
        ))
    }

    func testHalfOpacityAndPartialAlphaInsideSelection() throws {
        let base = try RGBAImage(width: 4, height: 1, pixels: [
            0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255
        ])
        let white = try RGBAImage(width: 4, height: 1, fill: 255)
        let result = try StrictSelectionCompositor.composite(
            base: base,
            patch: white,
            mask: .rectangle(PixelRect(x: 1, y: 0, width: 2, height: 1)),
            opacity: 0.5
        )
        XCTAssertEqual(result.image.pixels[0], 0)
        XCTAssertEqual(result.image.pixels[4], 128)
        XCTAssertEqual(result.image.pixels[8], 128)
        XCTAssertEqual(result.image.pixels[12], 0)
        XCTAssertEqual(result.image.pixels[7], 255)
        XCTAssertEqual(result.image.pixels[11], 255)
    }
}
