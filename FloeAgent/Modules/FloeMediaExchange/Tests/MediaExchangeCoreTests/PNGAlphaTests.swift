// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import MediaExchangeCore

final class PNGAlphaTests: XCTestCase {
    func testPNGDataSliceKeepsItsNonzeroStartIndex() throws {
        let image = try RGBAImage(width: 2, height: 1, pixels: [200, 100, 50, 1, 12, 34, 56, 255])
        var prefixed = Data(repeating: 0, count: 7)
        prefixed.append(try PNGCodec.encode(image))
        let slice = prefixed.dropFirst(7)
        XCTAssertEqual(slice.startIndex, 7)
        XCTAssertEqual(try PNGCodec.decode(slice), image)
    }

    /// This is the regression that the earlier research package could not pass:
    /// alpha=1 straight RGBA must survive encode/decode without premultiplication.
    func testAlphaOneRGBAUnpremultipliedPNGRoundTripIsExact() throws {
        let image = try RGBAImage(width: 8, height: 3, pixels: [
            200, 100, 50, 1,   1, 2, 3, 1,   255, 0, 128, 2,   0, 0, 0, 0,
            7, 8, 9, 1,       254, 253, 252, 1, 13, 17, 19, 1,  64, 32, 16, 3,
            10, 20, 30, 255,  90, 80, 70, 128, 5, 6, 7, 64,     0, 255, 0, 1,
            1, 1, 1, 1,       2, 2, 2, 2,     3, 3, 3, 3,       4, 4, 4, 4,
            11, 12, 13, 1,    14, 15, 16, 1,  17, 18, 19, 1,    20, 21, 22, 1,
            33, 44, 55, 1,    66, 77, 88, 1,  99, 111, 122, 1,  133, 144, 155, 1
        ])
        let encoded = try PNGCodec.encode(image)
        let decoded = try PNGCodec.decode(encoded)
        XCTAssertEqual(decoded, image, "alpha=1 colour bytes were changed by the PNG bridge")
        // Encoding the decoded value again must be stable as well.
        let encodedAgain = try PNGCodec.encode(decoded)
        XCTAssertEqual(try PNGCodec.decode(encodedAgain), image)
    }

    func testAlphaOneSurvivesORALayerBytePreservation() throws {
        let image = try RGBAImage(width: 3, height: 2, pixels: [
            200, 100, 50, 1,   1, 2, 3, 1,   255, 0, 128, 2,
            7, 8, 9, 1,        254, 253, 252, 1, 13, 17, 19, 1
        ])
        let layerPNG = try PNGCodec.encode(image)
        let document = ORADocument(
            width: 3,
            height: 2,
            layers: [
                ORALayer(name: "alpha-one", pngData: layerPNG),
                ORALayer(name: "opaque", pngData: try PNGCodec.encode(image))
            ],
            mergedPNG: layerPNG,
            thumbnailPNG: layerPNG
        )
        let destination = try TestSupport.temporaryDirectory("ora-alpha")
        defer { TestSupport.remove(destination) }
        let url = destination.appendingPathComponent("alpha.ora")
        try ORAArchive.write(document, to: url)
        let reread = try ORAArchive.read(from: url)
        XCTAssertEqual(reread.layers[0].pngData, layerPNG)
        XCTAssertEqual(reread.layers[1].pngData, layerPNG)
        let decoded = try PNGCodec.decode(reread.layers[0].pngData)
        XCTAssertEqual(decoded, image)
    }

    func testExistingORALayerBytesArePreservedOnRewrite() throws {
        let original = try ORAArchive.read(from: Fixture.url("Fixtures/ora/valid_baseline.ora"))
        let destination = try TestSupport.temporaryDirectory("ora-preserve")
        defer { TestSupport.remove(destination) }
        let url = destination.appendingPathComponent("preserve.ora")
        try ORAArchive.write(original, to: url)
        let reread = try ORAArchive.read(from: url)
        XCTAssertEqual(reread.layers.count, original.layers.count)
        for (actual, expected) in zip(reread.layers, original.layers) {
            XCTAssertEqual(actual.pngData, expected.pngData, "layer \(expected.name) bytes changed")
        }
    }

    func testOpaquePNGRoundTripIsExact() throws {
        let image = try RGBAImage(width: 12, height: 9) { x, y in
            (UInt8(x * 10), UInt8(y * 10), UInt8((x + y) * 5), 255)
        }
        XCTAssertEqual(try PNGCodec.decode(try PNGCodec.encode(image)), image)
    }

    func testPNGHeaderRejectsOversizedDimensionsBeforeDecode() throws {
        var data = try PNGCodec.encode(try RGBAImage(width: 4, height: 4, fill: 0))
        data[16] = 0
        data[17] = 0
        data[18] = 0x4E
        data[19] = 0x20
        data[20] = 0
        data[21] = 0
        data[22] = 0x4E
        data[23] = 0x20
        XCTAssertThrowsError(try PNGCodec.decode(data))
    }

    func testMalformedPNGAndPSDInputsFailClosed() throws {
        XCTAssertThrowsError(try PNGCodec.dimensions(Data()))
        XCTAssertThrowsError(try PNGCodec.dimensions(Data("not a png".utf8)))
        XCTAssertThrowsError(try PSDHeader.parse(Data()))
        XCTAssertThrowsError(try PSDHeader.parse(Data("not a psd file at all".utf8)))
    }
}
