// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MediaExchangeCore

final class PSDORACompatibilityTests: XCTestCase {
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

    func testEditableTextPSDIsPreservedOnlyAndNeverFlattened() throws {
        let codec = try PSDCodec.bundled()
        let data = try Fixture.data("Fixtures/psd/unsupported_text.psd")
        let compatibility = try codec.evaluateCompatibility(data)
        XCTAssertEqual(compatibility.status, .preservedOnly)
        XCTAssertTrue(compatibility.reasons.contains { $0.contains("text") })
        let result = try codec.importDocument(data)
        guard case let .preserved(original, _) = result else {
            return XCTFail("expected preserved result")
        }
        XCTAssertEqual(original, data)
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
