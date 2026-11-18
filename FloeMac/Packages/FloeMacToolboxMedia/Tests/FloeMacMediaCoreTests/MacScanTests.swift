import XCTest
import CoreGraphics
@testable import FloeMacMediaCore
import FloeToolboxCore
import FloeToolboxUtilities

@MainActor
final class MacScanSessionTests: XCTestCase {
    private func png(width: Int = 64, height: Int = 48) throws -> Data {
        let image = try XCTUnwrap(MacTestFixtures.colorImage(width: width, height: height))
        return try MacTestFixtures.pngData(for: image)
    }

    // MARK: - Import and page bounds

    func testImportAddsOneBoundedPage() throws {
        let session = MacScanSession()
        let width = 120
        let height = 80
        let page = try session.addImportedImage(data: png(width: width, height: height))
        XCTAssertEqual(session.pageCount, 1)
        XCTAssertEqual(page.source, .imported)
        XCTAssertEqual(page.pixelWidth, width)
        XCTAssertEqual(page.pixelHeight, height)
        XCTAssertFalse(page.wasDownsampled)
        XCTAssertEqual(session.notice, .pageAdded(1))
    }

    func testInvalidImportIsRejected() {
        let session = MacScanSession()
        XCTAssertThrowsError(try session.addImportedImage(data: Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? MacMediaFailure, .unreadable)
        }
        XCTAssertEqual(session.pageCount, 0)
    }

    func testOversizedImportIsRejectedBeforeDecode() {
        let session = MacScanSession()
        let oversized = Data(count: OpticsImageDecoder.maximumEncodedBytes + 1)
        XCTAssertThrowsError(try session.addImportedImage(data: oversized)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .fileTooLarge)
        }
    }

    func testPageCapIsEnforcedWithoutReplacingPages() throws {
        let session = MacScanSession()
        let data = try png(width: 8, height: 8)
        for index in 0..<MacScanSession.maximumPages {
            try session.addPage(try OpticsImageDecoder.decode(data), source: .imported)
            XCTAssertEqual(session.pageCount, index + 1)
        }
        XCTAssertThrowsError(try session.addImportedImage(data: data)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .pageLimit)
        }
        XCTAssertEqual(session.pageCount, MacScanSession.maximumPages)
    }

    // MARK: - Live codes

    func testLiveCodesDeduplicateAndBoundPayloads() {
        let session = MacScanSession()
        let code = MacCapturedCode(payload: "https://example.com/a", symbology: "org.iso.QRCode")
        XCTAssertEqual(session.acceptLiveCodes([code]), 1)
        XCTAssertEqual(session.acceptLiveCodes([code]), 0)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.results.first?.kind, .qrCode)
        XCTAssertEqual(session.results.first?.detail, "QRCode")

        let huge = String(repeating: "a", count: 8_193)
        XCTAssertEqual(session.acceptLiveCodes([MacCapturedCode(payload: huge, symbology: "code128")]), 0)
        XCTAssertEqual(session.results.count, 1)
    }

    func testResultCapKeepsSixtyFourAndReportsTruncation() {
        let session = MacScanSession()
        let codes = (0..<70).map { MacCapturedCode(payload: "code-\($0)", symbology: "code128") }
        let added = session.acceptLiveCodes(codes)
        XCTAssertEqual(added, MacScanSession.maximumResults)
        XCTAssertEqual(session.results.count, MacScanSession.maximumResults)
        XCTAssertEqual(session.notice, .resultsTruncated)
        XCTAssertEqual(session.results.last?.payload, "code-63")
    }

    // MARK: - Real recognition through the shared code

    func testQRCodeRecognitionFromSyntheticImage() async throws {
        let payload = "https://example.com/floe?q=1"
        let data = try ToolboxQR.png(text: payload, scale: 8)
        let session = MacScanSession()
        let page = try session.addImportedImage(data: data)
        let added = await session.recognizePage(id: page.id)
        XCTAssertGreaterThanOrEqual(added, 1)
        XCTAssertTrue(session.results.contains { $0.payload == payload })
        XCTAssertEqual(session.results.first { $0.payload == payload }?.kind, .qrCode)
        XCTAssertEqual(session.notice, .recognized(added))
    }

    func testRecognitionDerivativeIsBounded() throws {
        let image = try XCTUnwrap(MacTestFixtures.colorImage(width: 3_000, height: 1_000))
        let session = MacScanSession()
        let page = try session.addImportedImage(data: MacTestFixtures.pngData(for: image))
        let derivative = try MacScanRecognitionInput.data(for: page.image)
        let decoded = try OpticsImageDecoder.decode(derivative)
        XCTAssertEqual(max(decoded.pixelWidth, decoded.pixelHeight), MacScanRecognitionInput.maximumDimension)
        XCTAssertLessThan(derivative.count, OpticsImageDecoder.maximumEncodedBytes)
        // The retained/exported page keeps its full resolution.
        XCTAssertEqual(page.pixelWidth, 3_000)
        XCTAssertEqual(page.pixelHeight, 1_000)
    }

    func testSyntheticTextOCR() async throws {
        let image = try XCTUnwrap(MacTestFixtures.textImage("FLOE 1234"))
        let data = try MacTestFixtures.pngData(for: image)
        let session = MacScanSession()
        let page = try session.addImportedImage(data: data)
        _ = await session.recognizePage(id: page.id)
        let text = session.results
            .filter { $0.kind == .text }
            .map(\.payload)
            .joined(separator: " ")
            .uppercased()
        XCTAssertTrue(text.contains("FLOE") || text.contains("1234"),
                      "on-device OCR returned unexpected text: \(text)")
        XCTAssertNotNil(session.pages.first?.text)
        XCTAssertTrue(session.ocrCompletenessUnverified)
        XCTAssertFalse(session.canExportTXT)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .captureFailed("ocr-completeness-unverified"))
        }
    }

    func testRealFullPageOCRIsPreviewOnlyUntilCompletenessCanBeProven() async throws {
        let session = MacScanSession()
        let image = try XCTUnwrap(MacTestFixtures.textImage("PREVIEW 1234"))
        let page = try session.addImportedImage(data: MacTestFixtures.pngData(for: image))
        await session.recognizeAllPages()
        XCTAssertTrue(session.ocrCompletenessUnverified)
        XCTAssertNotEqual(session.notice, .pagesComplete(1))
        XCTAssertFalse(session.canExportTXT)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .captureFailed("ocr-completeness-unverified"))
        }
        session.removePage(id: page.id)
        XCTAssertFalse(session.ocrCompletenessUnverified)
    }

    func testRealEmptySinglePageResultStillRequiresCompletenessProof() async throws {
        let session = MacScanSession()
        let page = try session.addImportedImage(data: png())
        _ = await session.recognizePage(id: page.id)
        XCTAssertTrue(session.ocrCompletenessUnverified)
        XCTAssertNotEqual(session.notice, .pagesComplete(1))
        XCTAssertFalse(session.canExportTXT)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .captureFailed("ocr-completeness-unverified"))
        }
        session.clear()
        XCTAssertFalse(session.ocrCompletenessUnverified)
    }

    func testMultiPageOCRProducesLabelledBoundedText() async throws {
        let session = MacScanSession(testingCompleteTextRecognizer: { page in
            let text = page.pixelWidth == 1_000 ? "ALPHA PAGE ONE" : "BETA PAGE TWO"
            return [OpticsScanItem(kind: .text, payload: text, detail: "fixture")]
        })
        let first = try XCTUnwrap(MacTestFixtures.textImage("ALPHA PAGE ONE"))
        let second = try XCTUnwrap(MacTestFixtures.textImage("BETA PAGE TWO", width: 1_100))
        _ = try session.addImportedImage(data: MacTestFixtures.pngData(for: first))
        _ = try session.addImportedImage(data: MacTestFixtures.pngData(for: second))
        await session.recognizeAllPages()
        let text = try XCTUnwrap(session.pageText)
        XCTAssertTrue(text.contains("— 1 —"))
        XCTAssertTrue(text.contains("— 2 —"))
        XCTAssertLessThanOrEqual(text.utf8.count, MacScanSession.maximumPageTextBytes)
        XCTAssertEqual(session.notice, .pagesComplete(2))
        let upper = text.uppercased()
        XCTAssertTrue(upper.contains("ALPHA") && upper.contains("BETA"), "unexpected OCR: \(text)")
    }

    func testFailedPageRemainsVisibleAndPreventsCompleteTextExport() async throws {
        struct SyntheticFailure: Error {}
        let session = MacScanSession(testingCompleteTextRecognizer: { page in
            if page.pixelWidth == 64 { throw SyntheticFailure() }
            return [OpticsScanItem(kind: .text, payload: "first page", detail: "fixture")]
        })
        _ = try session.addImportedImage(data: png(width: 32, height: 24))
        let failed = try session.addImportedImage(data: png(width: 64, height: 24))
        await session.recognizeAllPages()

        XCTAssertEqual(session.pages[0].text, "first page")
        XCTAssertEqual(session.failedPageIndices, [2])
        XCTAssertEqual(session.lastFailure, .captureFailed("ocr-incomplete"))
        XCTAssertNil(session.pageText)
        XCTAssertNil(session.notice)
        XCTAssertFalse(session.canExportTXT)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .captureFailed("ocr-incomplete"))
        }

        session.removePage(id: failed.id)
        XCTAssertTrue(session.failedPageIndices.isEmpty)
        XCTAssertNil(session.lastFailure)
        XCTAssertTrue(session.canExportTXT)
        XCTAssertTrue(String(decoding: try session.makeTXT().data, as: UTF8.self).contains("first page"))
    }

    func testRecognizedTextLimitCountsUTF8BytesWithoutTruncation() async throws {
        let oversized = String(repeating: "界", count: 50_000)
        XCTAssertLessThan(oversized.count, MacScanSession.maximumPageTextBytes)
        XCTAssertGreaterThan(oversized.utf8.count, MacScanSession.maximumPageTextBytes)
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in
            [OpticsScanItem(kind: .text, payload: oversized, detail: "fixture")]
        })
        _ = try session.addImportedImage(data: png())
        await session.recognizeAllPages()

        XCTAssertTrue(session.textLimitExceeded)
        XCTAssertEqual(session.failedPageIndices, [1])
        XCTAssertEqual(session.lastFailure, .exportTooLarge)
        XCTAssertNil(session.pageText)
        XCTAssertNil(session.notice)
        XCTAssertFalse(session.canExportTXT)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .exportTooLarge)
        }
    }

    func testCombinedPagesOverLimitKeepPageTextAndRejectExport() async throws {
        let pageText = String(repeating: "a", count: 70_000)
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in
            [OpticsScanItem(kind: .text, payload: pageText, detail: "fixture")]
        })
        _ = try session.addImportedImage(data: png())
        _ = try session.addImportedImage(data: png())
        await session.recognizeAllPages()

        XCTAssertTrue(session.textLimitExceeded)
        XCTAssertTrue(session.failedPageIndices.isEmpty)
        XCTAssertEqual(session.pages.map(\.text), [pageText, pageText])
        XCTAssertEqual(session.lastFailure, .exportTooLarge)
        XCTAssertNil(session.pageText)
        XCTAssertNil(session.notice)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .exportTooLarge)
        }
    }

    func testAddingPageInvalidatesPreviouslyCompleteDocument() async throws {
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in
            [OpticsScanItem(kind: .text, payload: "recognized", detail: "fixture")]
        })
        _ = try session.addImportedImage(data: png())
        await session.recognizeAllPages()
        XCTAssertTrue(session.canExportTXT)
        _ = try session.addImportedImage(data: png())
        XCTAssertNil(session.pageText)
        XCTAssertFalse(session.canExportTXT)
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .captureFailed("ocr-incomplete"))
        }
        await session.recognizeAllPages()
        XCTAssertTrue(session.canExportTXT)
    }

    func testRecognitionCancellationLeavesResultsUntouched() async throws {
        let session = MacScanSession()
        let code = MacCapturedCode(payload: "keep-me", symbology: "org.iso.QRCode")
        _ = session.acceptLiveCodes([code])
        session.cancelRecognition()
        let page = try session.addImportedImage(data: try ToolboxQR.png(text: "other"))
        _ = await session.recognizePage(id: page.id)
        XCTAssertTrue(session.results.contains { $0.payload == "keep-me" })
    }

    // MARK: - Exports

    func testPNGExportKeepsPagePixels() throws {
        let session = MacScanSession()
        let page = try session.addImportedImage(data: png(width: 96, height: 60))
        let artifact = try session.makePNG()
        XCTAssertEqual(artifact.format, .png)
        XCTAssertTrue(artifact.suggestedFilename.hasPrefix("floe-scan-"))
        XCTAssertEqual([UInt8](artifact.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let decoded = try OpticsImageDecoder.decode(artifact.data)
        XCTAssertEqual(decoded.pixelWidth, 96)
        XCTAssertEqual(decoded.pixelHeight, 60)
        XCTAssertEqual(try session.makePNG(pageID: page.id).data, artifact.data)
    }

    func testPDFExportContainsEveryPageWithOwnAspect() throws {
        let session = MacScanSession()
        _ = try session.addImportedImage(data: png(width: 400, height: 200))
        _ = try session.addImportedImage(data: png(width: 300, height: 600))
        let artifact = try session.makePDF()
        XCTAssertEqual(artifact.format, .pdf)
        XCTAssertTrue(String(decoding: artifact.data.prefix(5), as: UTF8.self).hasPrefix("%PDF"))
        let provider = try XCTUnwrap(CGDataProvider(data: artifact.data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 2)
        let first = try XCTUnwrap(document.page(at: 1))
        let second = try XCTUnwrap(document.page(at: 2))
        XCTAssertEqual(first.getBoxRect(.mediaBox).width / first.getBoxRect(.mediaBox).height,
                       2, accuracy: 0.02)
        XCTAssertEqual(second.getBoxRect(.mediaBox).width / second.getBoxRect(.mediaBox).height,
                       0.5, accuracy: 0.02)
    }

    func testTXTExportRequiresRecognizedText() async throws {
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in
            [OpticsScanItem(kind: .text, payload: "EXPORT ME 9021", detail: "fixture")]
        })
        XCTAssertThrowsError(try session.makeTXT()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .emptyExport)
        }
        let image = try XCTUnwrap(MacTestFixtures.textImage("EXPORT ME 9021"))
        _ = try session.addImportedImage(data: MacTestFixtures.pngData(for: image))
        await session.recognizeAllPages()
        let text = try XCTUnwrap(session.pageText)
        let artifact = try session.makeTXT()
        XCTAssertEqual(artifact.format, .txt)
        XCTAssertEqual(String(decoding: artifact.data, as: UTF8.self), text)
    }

    func testEmptyExportsFailHonestly() {
        let session = MacScanSession()
        XCTAssertThrowsError(try session.makePNG()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .emptyExport)
        }
        XCTAssertThrowsError(try session.makePDF()) { error in
            XCTAssertEqual(error as? MacMediaFailure, .emptyExport)
        }
    }

    // MARK: - Removal

    func testTXTUsesPerPageTextWithoutFullDocumentPass() async throws {
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in
            [OpticsScanItem(kind: .text, payload: "SINGLE 4455", detail: "fixture")]
        })
        let image = try XCTUnwrap(MacTestFixtures.textImage("SINGLE 4455"))
        let page = try session.addImportedImage(data: MacTestFixtures.pngData(for: image))
        _ = await session.recognizePage(id: page.id)
        XCTAssertNotNil(session.pages.first?.text)
        let artifact = try session.makeTXT()
        let text = String(decoding: artifact.data, as: UTF8.self)
        XCTAssertTrue(text.contains("— 1 —"))
        XCTAssertLessThanOrEqual(text.utf8.count, MacScanSession.maximumPageTextBytes)
    }

    func testRemovingAPageInvalidatesCombinedText() async throws {
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in
            [OpticsScanItem(kind: .text, payload: "REMOVE ME", detail: "fixture")]
        })
        let image = try XCTUnwrap(MacTestFixtures.textImage("REMOVE ME"))
        let page = try session.addImportedImage(data: MacTestFixtures.pngData(for: image))
        await session.recognizeAllPages()
        XCTAssertNotNil(session.pageText)
        session.removePage(id: page.id)
        XCTAssertEqual(session.pageCount, 0)
        XCTAssertNil(session.pageText)
        XCTAssertEqual(session.notice, .pageRemoved)
    }

    func testClearDropsPagesResultsAndText() throws {
        let session = MacScanSession()
        _ = session.acceptLiveCodes([MacCapturedCode(payload: "x", symbology: "code128")])
        _ = try session.addImportedImage(data: png())
        session.clear()
        XCTAssertEqual(session.results.count, 0)
        XCTAssertEqual(session.pageCount, 0)
        XCTAssertNil(session.pageText)
        XCTAssertEqual(session.notice, .cleared)
    }
}

final class MacToolboxBaselineTests: XCTestCase {
    func testCatalogStillHasThirtyOneToolsAndEveryOneIsClassified() {
        XCTAssertEqual(ToolboxTool.allCases.count, MacToolboxBaseline.catalogCount)
        XCTAssertEqual(MacToolboxBaseline.entries.count, MacToolboxBaseline.catalogCount)
        XCTAssertEqual(Set(MacToolboxBaseline.entries.map(\.tool)), Set(ToolboxTool.allCases))
        XCTAssertTrue(MacToolboxBaseline.entries.allSatisfy { !$0.note.isEmpty })
    }

    func testCandidateImplementsExactlySoundMagnifierScanner() {
        let native = MacToolboxBaseline.entries
            .filter { $0.readiness == .candidateNative }
            .map(\.tool)
        XCTAssertEqual(Set(native), Set(MacToolboxBaseline.candidateTools))
        XCTAssertEqual(Set(native), Set([.sound, .magnifier, .scanner]))
    }

    func testDeviceLimitedEntriesAreTheSensorDependentTools() {
        let limited = Set(MacToolboxBaseline.entries
            .filter { $0.readiness == .deviceLimited }
            .map(\.tool))
        XCTAssertEqual(limited, Set([.level, .motion, .compass, .measure, .barometer]))
    }

    func testEveryOtherToolIsReusableSourceNotClaimedComplete() {
        let reusable = MacToolboxBaseline.entries
            .filter { $0.readiness == .reusableSource }
            .map(\.tool)
        XCTAssertEqual(reusable.count, 23)
        XCTAssertFalse(reusable.contains(.sound))
        XCTAssertFalse(reusable.contains(.magnifier))
        XCTAssertFalse(reusable.contains(.scanner))
    }
}
