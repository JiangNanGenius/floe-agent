// SPDX-License-Identifier: MPL-2.0

import XCTest
import JavaScriptCore
@testable import MediaExchangeCore

final class PSDORACompatibilityTests: XCTestCase {
    func testEditableGroupsAndSingleStyleTextRoundTrip() throws {
        let clear = try RGBAImage(width: 1, height: 1, pixels: [0, 0, 0, 0])
        let pixels = try RGBAImage(width: 2, height: 2, pixels: Array(repeating: [80, 120, 160, 255], count: 4).flatMap { $0 })
        let input = PortableDocument(width: 32, height: 32, layers: [
            .init(name: "Group", image: clear, group: true),
            .init(name: "Photo", image: pixels, left: 3, top: 4, depth: 1),
            .init(name: "Title", image: pixels, left: 8, top: 9, depth: 1,
                  text: .init(text: "Floe", fontName: "Helvetica", fontSize: 12, colorHex: "#123456"))
        ])
        let codec = try PSDCodec.bundled(), bytes = try LayeredExchange.toPSD(input, codec: codec)
        XCTAssertEqual(try codec.evaluateCompatibility(bytes).status, .supported)
        let output = try LayeredExchange.fromPSD(codec.read(bytes))
        XCTAssertEqual(output.layers.map(\.depth), [0, 1, 1])
        XCTAssertTrue(output.layers[0].group)
        XCTAssertEqual(output.layers[1].image, pixels)
        XCTAssertEqual(output.layers[2].text?.text, "Floe")
        XCTAssertEqual(output.layers[2].text?.fontName, "Helvetica")
        XCTAssertEqual(output.layers[2].text?.fontSize, 12)
        XCTAssertEqual(output.layers[2].text?.colorHex.lowercased(), "#123456")
    }

    func testMaskBackgroundAndDisabledFlagSurvivePSD() throws {
        let pixels = try RGBAImage(width: 2, height: 1, pixels: [100, 40, 20, 255, 20, 40, 100, 255])
        let mask = PortableMask(image: try .init(width: 1, height: 1, pixels: [64, 64, 64, 255]),
                                left: 0, top: 0, isEnabled: false, defaultColor: 255)
        let input = PortableDocument(width: 8, height: 8, layers: [.init(name: "Masked", image: pixels, mask: mask)])
        let output = try LayeredExchange.fromPSD(PSDCodec.bundled().read(LayeredExchange.toPSD(input, codec: PSDCodec.bundled())))
        XCTAssertEqual(output.layers[0].mask?.isEnabled, false)
        XCTAssertEqual(output.layers[0].mask?.defaultColor, 255)
        XCTAssertEqual(output.layers[0].mask?.image.pixels[0], 64)
        XCTAssertEqual(try PortableCompositor.flatten(input).pixel(x: 0, y: 0).a, 255)
    }

    func testInvalidNestedLayerOrderIsRefused() throws {
        let pixels = try RGBAImage(width: 1, height: 1, pixels: [1, 2, 3, 255])
        XCTAssertThrowsError(try PortableCompositor.flatten(.init(width: 4, height: 4,
            layers: [.init(name: "No parent", image: pixels, depth: 1)])))
    }

    func testBundledPSDCodecReportsPinnedVersion() throws {
        let codec = try PSDCodec.bundled()
        let info = try codec.codecInfo()
        XCTAssertTrue(info.contains("ag-psd-34.1.0"), info)
        XCTAssertTrue(info.contains("\"canvas\":0"), info)
    }

    func testUnsupportedPSDHeadersArePreservedWithOriginalBytes() throws {
        let codec = try PSDCodec.bundled()
        for name in [
            "unsupported_cmyk_header.psd",
            "unsupported_16bit_header.psd",
            "unsupported_psb_header.psd",
            "oversized_header.psd",
            "overflow_dimensions.psd"
        ] {
            let data = try Fixture.data("Fixtures/psd/\(name)")
            let hash = TestSupport.sha256(data)
            let compatibility = try codec.evaluateCompatibility(data)
            XCTAssertEqual(compatibility.status, .preservedOnly, name)
            XCTAssertFalse(compatibility.reasons.isEmpty, name)
            XCTAssertThrowsError(try codec.read(data), name)
            let result = try codec.importDocument(data)
            guard case let .preserved(original, _) = result else {
                return XCTFail("\(name): expected preserved result")
            }
            XCTAssertEqual(original, data)
            XCTAssertEqual(TestSupport.sha256(data), hash)
        }
    }

    func testTextWithoutCachedGeometryStaysPreservedAndNeverFlattens() throws {
        let codec = try PSDCodec.bundled(), data = try Fixture.data("Fixtures/psd/unsupported_text.psd")
        guard case .preserved(let original, let compatibility) = try codec.importDocument(data) else { return XCTFail("text without cached geometry must stay preserved") }
        XCTAssertEqual(compatibility.status, .preservedOnly)
        XCTAssertTrue(compatibility.reasons.contains(where: { $0.contains("text") }))
        XCTAssertEqual(original, data)
    }

    func testRichTextRemainsPreservedOnlyWithExactOriginalBytes() throws {
        let context = try XCTUnwrap(JSContext())
        let script = try String(contentsOf: Fixture.root.appendingPathComponent("Sources/MediaExchangeCore/Resources/ag-psd-bundle.js"), encoding: .utf8)
        context.evaluateScript(script)
        let js = """
        agPsd.initializeCanvas(function(){throw new Error('unexpected canvas');}, function(w,h){return {width:w,height:h,data:new Uint8ClampedArray(w*h*4)};});
        var pixel={width:2,height:2,data:new Uint8ClampedArray(16)};
        var text={text:'AB',transform:[1,0,0,1,0,12],style:{font:{name:'Helvetica'},fontSize:12,fillColor:{r:255,g:0,b:0}},styleRuns:[{length:1,style:{fillColor:{r:255,g:0,b:0}}},{length:1,style:{fillColor:{r:0,g:0,b:255}}}]};
        agPsd.byteArrayToBase64(agPsd.writePsdUint8Array({width:2,height:2,imageData:pixel,children:[{name:'Rich text',imageData:pixel,text:text}]},{noBackground:true}));
        """
        let encoded = try XCTUnwrap(context.evaluateScript(js)?.toString())
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        let data = try XCTUnwrap(Data(base64Encoded: encoded)), codec = try PSDCodec.bundled()
        guard case .preserved(let original, let compatibility) = try codec.importDocument(data) else { return XCTFail("rich text must stay preserved") }
        XCTAssertEqual(original, data)
        XCTAssertTrue(compatibility.reasons.contains(where: { $0.contains("text") }))
    }

    func testBaselinePSDReadsEditableLayersAndRoundTripsBytes() throws {
        let codec = try PSDCodec.bundled()
        let data = try Fixture.data("Fixtures/psd/baseline_rgb8.psd")
        let result = try codec.read(data)
        XCTAssertEqual(result.width, 128)
        XCTAssertEqual(result.height, 96)
        XCTAssertEqual(result.canvasFactoryCalls, 0)
        XCTAssertGreaterThan(result.imageDataFactoryCalls, 0)
        XCTAssertEqual(try codec.roundTrip(data), data)
    }

    func testORAAdvancedFeaturesAreExplicitlyReported() throws {
        let document = try ORAArchive.read(from: Fixture.url("Fixtures/ora/advanced_ops.ora"))
        XCTAssertEqual(document.layers.count, 2)
        XCTAssertTrue(document.layers.contains { $0.alphaPreserve })
        XCTAssertThrowsError(try ORACompositor.flatten(document))
        XCTAssertThrowsError(try LayeredExchange.fromORA(document))
    }

    func testORAMalformedArchivesAndTraversalFailClosed() throws {
        let cases = [
            "missing_mimetype.ora", "mimetype_late.ora", "mimetype_compressed.ora",
            "bad_mimetype.ora", "missing_merged.ora", "missing_thumbnail.ora",
            "duplicate_layer.ora", "path_traversal.ora", "nested_stack.ora",
            "text_element.ora", "oversized_dimensions.ora", "invalid_png.ora",
            "truncated.ora", "entity_xml.ora", "oversized_entry.ora"
        ]
        for name in cases {
            XCTAssertThrowsError(
                try ORAArchive.read(from: Fixture.url("Fixtures/ora/\(name)")),
                name
            )
        }
        for path in ["../x.png", "/tmp/x.png", "data/../../x.png", "data\\x.png", "C:data/x.png", "", "data//x.png"] {
            XCTAssertThrowsError(try ORAArchive.validatePath(path), "expected reject: \(path)")
        }
        XCTAssertNoThrow(try ORAArchive.validatePath("data/layer0.png"))
    }

    func testPSDToORARejectsMasksAndClippingInsteadOfBaking() throws {
        let psd = try PSDCodec.bundled().read(try Fixture.data("Fixtures/psd/advanced_masks_blends.psd"))
        let portable = try LayeredExchange.fromPSD(psd)
        XCTAssertNoThrow(try PortableCompositor.flatten(portable))
        XCTAssertThrowsError(try LayeredExchange.toORA(portable)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("mask") || message.contains("clipping"), message)
        }
    }
}
