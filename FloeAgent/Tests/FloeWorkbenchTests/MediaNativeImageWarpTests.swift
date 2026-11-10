// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Synchronization
@testable import FloeWorkbench

enum WarpFixture {
    static let color = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    static func image(width: Int = 128, height: Int = 96, pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let value = pixel(x,y); for c in 0..<4 { bytes[(y*width+x)*4+c] = value[c] }
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: color,
            bitmapInfo: .init(rawValue: info), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width*image.height*4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width*4, space: color, bitmapInfo: info))
            context.setBlendMode(.copy); context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    static func at(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let bytes = try pixels(image), offset = (y*image.width+x)*4; return Array(bytes[offset..<(offset+4)])
    }
    static func shift(_ quad: MediaImageWarpQuad, dx: Double, dy: Double) throws -> MediaImageWarpQuad {
        try .init(points: quad.points.map { .init(x: $0.x+dx, y: $0.y+dy) })
    }
    static func save(_ image: CGImage, name: String) throws {
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
        let input: CGImageSource
        if let base = ProcessInfo.processInfo.environment["FLOE_IMAGE_WARP_PROOF_ROOT"] {
            let url = URL(fileURLWithPath: base).appendingPathComponent(name+".png")
            try (data as Data).write(to: url)
            input = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        } else { input = try XCTUnwrap(CGImageSourceCreateWithData(data, nil)) }
        let reopened = try XCTUnwrap(CGImageSourceCreateImageAtIndex(input, 0, nil))
        XCTAssertEqual(reopened.width, image.width); XCTAssertEqual(reopened.height, image.height)
        XCTAssertEqual(try pixels(reopened), try pixels(image))
    }
}

final class ImageWarpTests: XCTestCase, @unchecked Sendable {
    func testGeometryUsesActualVisiblePixelsIntersectedWithCoverageAndKeepsIdentityExact() throws {
        let source = try WarpFixture.image { x,y in (16..<64).contains(x) && (12..<52).contains(y) ? [255,0,0,255] : [0,0,0,0] }
        let mask = try WarpFixture.image { x,y in (20..<48).contains(x) && (20..<42).contains(y) ? [255,255,255,255] : [0,0,0,0] }
        let all = try MediaNativeImageWarp.geometry(source), selected = try MediaNativeImageWarp.geometry(source, coverage: mask)
        XCTAssertEqual(all.contentBounds.x, 16); XCTAssertEqual(all.contentBounds.y, 12)
        XCTAssertEqual(all.contentBounds.width, 48); XCTAssertEqual(all.contentBounds.height, 40)
        XCTAssertEqual(selected.contentBounds.x, 20); XCTAssertEqual(selected.contentBounds.y, 20)
        XCTAssertEqual(selected.contentBounds.width, 28); XCTAssertEqual(selected.contentBounds.height, 22)
        XCTAssertEqual(all.pixelSHA256, selected.pixelSHA256); XCTAssertNotNil(selected.coverageSHA256)
        for mode in [MediaImageWarpMode.perspective, .bilinear] {
            let result = try MediaNativeImageWarp.apply(source, mode: mode, destination: selected.sourceQuad, coverage: mask)
            XCTAssertEqual(try WarpFixture.pixels(result.image), try WarpFixture.pixels(source))
            XCTAssertEqual(try WarpFixture.pixels(XCTUnwrap(result.transformedCoverage)), try WarpFixture.pixels(mask))
        }
    }
    func testBothModesReallyTranslateOffCenterSourceInBothAxesAndReadBackPNG() throws {
        let source = try WarpFixture.image { x,y in
            guard (16..<48).contains(x), (12..<44).contains(y) else { return [0,0,0,0] }
            return y < 28 ? [255,0,0,255] : [0,0,255,255]
        }
        let before = try WarpFixture.pixels(source), geometry = try MediaNativeImageWarp.geometry(source)
        let target = try WarpFixture.shift(geometry.sourceQuad, dx: 48.0/128, dy: 28.0/96)
        try WarpFixture.save(source, name: "source-offset")
        for mode in [MediaImageWarpMode.perspective, .bilinear] {
            let result = try MediaNativeImageWarp.apply(source, mode: mode, destination: target)
            XCTAssertEqual(try WarpFixture.at(result.image, x: 24, y: 20)[3], 0)
            XCTAssertGreaterThan(try WarpFixture.at(result.image, x: 72, y: 48)[0], 245)
            XCTAssertGreaterThan(try WarpFixture.at(result.image, x: 72, y: 64)[2], 245)
            try WarpFixture.save(result.image, name: "translated-"+mode.rawValue)
        }
        XCTAssertEqual(try WarpFixture.pixels(source), before)
    }
    func testPerspectiveAndBilinearHaveDistinctMeasuredInteriorMappings() throws {
        let source = try WarpFixture.image(width: 240, height: 200) { x,y in
            guard (40..<200).contains(x), (20..<180).contains(y) else { return [0,0,0,0] }
            return [UInt8((x-40)*255/159),UInt8((y-20)*255/159),0,255]
        }
        let quad = MediaImageWarpQuad(topLeft: .init(x: 0.15,y: 0.1), topRight: .init(x: 0.9,y: 0.1), bottomRight: .init(x: 0.65,y: 0.9), bottomLeft: .init(x: 0.35,y: 0.9))
        let center = MediaImageWarpPoint(x: 0.5,y: 0.5)
        let projectivePoint = try MediaNativeImageWarp.mapUnitPoint(center, to: quad, mode: .perspective)
        let bilinearPoint = try MediaNativeImageWarp.mapUnitPoint(center, to: quad, mode: .bilinear)
        XCTAssertGreaterThan(abs(projectivePoint.y-bilinearPoint.y), 0.1)
        let perspective = try MediaNativeImageWarp.apply(source, mode: .perspective, destination: quad)
        let bilinear = try MediaNativeImageWarp.apply(source, mode: .bilinear, destination: quad)
        for (result,point) in [(perspective,projectivePoint),(bilinear,bilinearPoint)] {
            let values = try WarpFixture.at(result.image, x: Int(point.x*240), y: Int(point.y*200))
            XCTAssertEqual(Double(values[0]), 128, accuracy: 6); XCTAssertEqual(Double(values[1]), 128, accuracy: 6)
            XCTAssertEqual(values[3], 255)
            try WarpFixture.save(result.image, name: "trapezoid-"+result.mode.rawValue)
        }
        XCTAssertNotEqual(try WarpFixture.pixels(perspective.image), try WarpFixture.pixels(bilinear.image))
        let metrics: [String:Any] = ["perspectiveCenter": [projectivePoint.x,projectivePoint.y], "bilinearCenter": [bilinearPoint.x,bilinearPoint.y], "coreImagePerspective": true, "bilinearPixelInverse": true]
        guard let root = ProcessInfo.processInfo.environment["FLOE_IMAGE_WARP_PROOF_ROOT"] else { return }
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: root).appendingPathComponent("mapping-measurements.json"))
    }
    func testSelectionMovesHolesAndPreservesUnselectedOriginalRatherThanCroppingDestination() throws {
        let source = try WarpFixture.image { x,y in (8..<56).contains(x) && (16..<64).contains(y) ? [255,0,0,255] : [0,0,0,0] }
        let mask = try WarpFixture.image { x,y in
            guard (16..<48).contains(x), (24..<56).contains(y), !((28..<36).contains(x) && (36..<44).contains(y)) else { return [0,0,0,0] }
            return [255,255,255,255]
        }
        let geometry = try MediaNativeImageWarp.geometry(source, coverage: mask)
        let target = try WarpFixture.shift(geometry.sourceQuad, dx: 64.0/128, dy: 0)
        for mode in [MediaImageWarpMode.perspective,.bilinear] {
            let result = try MediaNativeImageWarp.apply(source, mode: mode, destination: target, coverage: mask)
            XCTAssertEqual(try WarpFixture.at(result.image, x: 12, y: 40), [255,0,0,255])
            XCTAssertEqual(try WarpFixture.at(result.image, x: 20, y: 30)[3], 0)
            XCTAssertEqual(try WarpFixture.at(result.image, x: 32, y: 40), [255,0,0,255])
            XCTAssertGreaterThan(try WarpFixture.at(result.image, x: 84, y: 30)[3], 250)
            XCTAssertEqual(try WarpFixture.at(result.image, x: 96, y: 40)[3], 0)
            let moved = try XCTUnwrap(result.transformedCoverage)
            XCTAssertEqual(try WarpFixture.at(moved, x: 96, y: 40)[3], 0)
            XCTAssertGreaterThan(try WarpFixture.at(moved, x: 84, y: 30)[3], 250)
            XCTAssertEqual(try WarpFixture.at(moved, x: 20, y: 30)[3], 0)
            try WarpFixture.save(result.image, name: "selection-"+mode.rawValue)
            try WarpFixture.save(moved, name: "selection-moved-mask-"+mode.rawValue)
        }
    }
    func testSoftCoverageAndPremultipliedAlphaDoNotAddOpaqueOrBlackPixels() throws {
        let source = try WarpFixture.image { x,y in (16..<48).contains(x) && (16..<48).contains(y) ? [128,0,0,128] : [0,0,0,0] }
        let mask = try WarpFixture.image { x,y in (16..<48).contains(x) && (16..<48).contains(y) ? [128,128,128,128] : [0,0,0,0] }
        let geometry = try MediaNativeImageWarp.geometry(source, coverage: mask), target = try WarpFixture.shift(geometry.sourceQuad, dx: 48.0/128, dy: 0)
        for mode in [MediaImageWarpMode.perspective,.bilinear] {
            let result = try MediaNativeImageWarp.apply(source, mode: mode, destination: target, coverage: mask)
            let moved = try WarpFixture.at(result.image, x: 80, y: 32), remaining = try WarpFixture.at(result.image, x: 32, y: 32)
            XCTAssertEqual(Double(moved[3]), 64, accuracy: 2); XCTAssertEqual(Double(remaining[3]), 64, accuracy: 2)
            XCTAssertEqual(Double(moved[0]), Double(moved[3]), accuracy: 2)
            let values = try WarpFixture.pixels(result.image)
            for i in stride(from: 0, to: values.count, by: 4) {
                XCTAssertLessThanOrEqual(values[i], values[i+3]); XCTAssertEqual(values[i+1], 0); XCTAssertEqual(values[i+2], 0)
            }
        }
    }
    func testConvexMirrorAndClippedMappingsAreRealWhileFoldedAndUnsupportedInputsFail() throws {
        let source = try WarpFixture.image { x,y in (20..<60).contains(x) && (20..<60).contains(y) ? (x<40 ? [255,0,0,255] : [0,0,255,255]) : [0,0,0,0] }
        let geometry = try MediaNativeImageWarp.geometry(source), p = geometry.sourceQuad
        let mirror = MediaImageWarpQuad(topLeft: p.topRight, topRight: p.topLeft, bottomRight: p.bottomLeft, bottomLeft: p.bottomRight)
        for mode in [MediaImageWarpMode.perspective,.bilinear] {
            let result = try MediaNativeImageWarp.apply(source, mode: mode, destination: mirror)
            XCTAssertGreaterThan(try WarpFixture.at(result.image, x: 28, y: 40)[2], 245)
            XCTAssertGreaterThan(try WarpFixture.at(result.image, x: 52, y: 40)[0], 245)
            let clipped = try MediaNativeImageWarp.apply(source, mode: mode, destination: WarpFixture.shift(p, dx: -0.3, dy: -0.3))
            XCTAssertEqual(clipped.image.width, source.width); XCTAssertGreaterThan(try WarpFixture.at(clipped.image, x: 4, y: 4)[3], 0)
        }
        let folded = MediaImageWarpQuad(topLeft: p.topLeft, topRight: p.bottomRight, bottomRight: p.topRight, bottomLeft: p.bottomLeft)
        XCTAssertThrowsError(try MediaNativeImageWarp.apply(source, mode: .bilinear, destination: folded))
        let empty = try WarpFixture.image { _,_ in [0,0,0,0] }; XCTAssertThrowsError(try MediaNativeImageWarp.geometry(empty))
        let tooWide = try WarpFixture.image(width: 9_000, height: 1) { _,_ in [0,0,0,255] }; XCTAssertThrowsError(try MediaNativeImageWarp.geometry(tooWide))
        XCTAssertThrowsError(try MediaNativeImageWarp.geometry(source, coverage: empty.cropping(to: .init(x: 0,y: 0,width: 16,height: 16))))
    }
    func testCancellationInterruptsRealBilinearWorkWithoutChangingTheSource() throws {
        let source = try WarpFixture.image(width: 512,height: 512) { x,y in [UInt8(x%255),UInt8(y%255),0,255] }
        let before = try WarpFixture.pixels(source), calls = Mutex(0)
        let quad = MediaImageWarpQuad(topLeft: .init(x: 0,y: 0),topRight: .init(x: 1,y: 0.08),bottomRight: .init(x: 0.9,y: 1),bottomLeft: .init(x: 0.1,y: 0.95))
        do { _ = try MediaNativeImageWarp.apply(source, mode: .bilinear, destination: quad, work: .init(isCancelled: { calls.withLock { $0 += 1; return $0 > 40 } })); XCTFail("cancelled processing succeeded") }
        catch MediaImageWarpError.cancelled {}
        XCTAssertGreaterThan(calls.withLock { $0 },40); XCTAssertEqual(try WarpFixture.pixels(source),before)
    }
}
