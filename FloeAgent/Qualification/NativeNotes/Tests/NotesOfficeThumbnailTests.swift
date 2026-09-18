// SPDX-License-Identifier: MPL-2.0
//
// Targeted checks for the Notes unified library-cover mechanism and the
// `--preview-fixture` Office thumbnail qualification host.
//
// They assert that:
//  * the fixtures are real, inspectable OOXML packages that the shared importer
//    accepts as `.office` documents pointing at an intact CAS resource;
//  * every one of the six per-sample checks renders through the production card
//    path — `NoteFileImporter` -> extensionless CAS resource -> shared
//    `NotesDocumentCoverService` staging and host gate — while asserting the
//    original file name, the exact source bytes and a real Quick Look content
//    image. That is the path a Notes card actually uses;
//  * Quick Look output is real document content, never a generic file icon;
//  * the shared `NotesDocumentCoverService` returns a `.quickLookThumbnail`
//    source for real Word/Excel/PPT packages;
//  * when Quick Look only offers an icon, the bounded generator stops, reports
//    the icon fallback and never returns it as content;
//  * the bounded native OOXML content-summary fallback renders a real image
//    from the document's own text/cells, including when the resource is the
//    extensionless Notes CAS path and Quick Look produced no content at all
//    (forced through the per-call render request seam, never a process-global
//    mock), with bounded redacted failure diagnostics (attempts/timeout/
//    whitelisted numeric error identity/fallback stage);
//  * the mind-map cover is a bounded structural render of the node tree;
//  * the bundled viewer paints real DXF and DWG geometry (non-background
//    pixels) through the shared offscreen renderer, and a rename revision
//    re-renders from the same immutable engineering resource.
//
// A failure is a failure: there is no all-fail skip left to mask a regression,
// and a generic icon can never satisfy the real-thumbnail assertions.
import XCTest
import UIKit
import FloeNotes
import FloeDocuments
@testable import FloeNotesNativeQualification

@MainActor
final class NotesOfficeThumbnailTests: XCTestCase {
    private func makeScratchDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-office-thumb-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every sample must be a genuine Office package that the shared importer
    /// accepts as an `.office` document pointing at an intact CAS resource.
    func testPreviewFixtureFactoryImportsRealOfficeDocuments() async throws {
        let root = makeScratchDirectory("import")
        defer { try? FileManager.default.removeItem(at: root) }

        let samples = PreviewFixtureFactory.samples
        XCTAssertGreaterThanOrEqual(Set(samples.map(\.format)).count, 3, "All three Office formats must be represented")

        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        XCTAssertEqual(urls.count, samples.count)

        let expectedKinds: [PreviewFixtureSample.Format: OfficeDocumentKind] = [
            .word: .word, .excel: .workbook, .powerpoint: .presentation
        ]
        for (sample, url) in zip(samples, urls) {
            let snapshot = try OfficeDocumentService.inspect(url: url)
            XCTAssertEqual(snapshot.kind, expectedKinds[sample.format])
            XCTAssertGreaterThan(snapshot.packageBytes, 0)
            XCTAssertFalse(snapshot.fields.isEmpty, "\(sample.fileName) has no inspectable content")
        }

        let store = try NotesStore(root: root.appendingPathComponent("store"))
        var imported: [NoteDocument] = []
        for url in urls {
            let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
            imported.append(try await store.create(draft))
        }
        XCTAssertEqual(imported.count, samples.count)

        let extensions = Set(imported.compactMap { document in
            document.officeFileName.map { ($0 as NSString).pathExtension.lowercased() }
        })
        XCTAssertEqual(extensions, ["docx", "xlsx", "pptx"])

        for (document, url) in zip(imported, urls) {
            XCTAssertEqual(document.kind, .office)
            let resourceID = try XCTUnwrap(document.officeResourceID)
            XCTAssertEqual(document.officeFileName, url.lastPathComponent)
            let resource = try await store.resourceURL(resourceID)
            XCTAssertEqual(try Data(contentsOf: resource), try Data(contentsOf: url),
                           "The thumbnail source must be the exact generated package")
        }
    }

    // MARK: - Quick Look content checks (one independent test per sample)

    func testQuickLookRendersWordBusinessWeekly() async throws {
        try await assertSampleRenders("商务周报.docx")
    }

    func testQuickLookRendersWordMeetingNotes() async throws {
        try await assertSampleRenders("meeting-notes.docx")
    }

    func testQuickLookRendersExcelQuarterlySummary() async throws {
        try await assertSampleRenders("季度数据汇总.xlsx")
    }

    func testQuickLookRendersExcelBudgetForecast() async throws {
        try await assertSampleRenders("budget-forecast.xlsx")
    }

    func testQuickLookRendersPowerPointProductRoadmap() async throws {
        try await assertSampleRenders("产品路线图.pptx")
    }

    func testQuickLookRendersPowerPointDesignReview() async throws {
        try await assertSampleRenders("design-review.pptx")
    }

    /// The unified cover service must return a real Quick Look thumbnail source
    /// (not `.unsupported`, not `.officeContentSummary`) for every Office type
    /// imported through the same `NoteFileImporter` path the app uses. This is
    /// the mechanism-level check that a generic file icon can never satisfy.
    func testCoverServiceReturnsQuickLookContentForEachOfficeType() async throws {
        let root = makeScratchDirectory("cover-service")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        let wanted: [(String, String)] = [
            ("商务周报.docx", "docx"),
            ("季度数据汇总.xlsx", "xlsx"),
            ("产品路线图.pptx", "pptx")
        ]
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        for (fileName, fileExtension) in wanted {
            let url = try XCTUnwrap(urls.first { $0.lastPathComponent == fileName })
            let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
            let document = try await store.create(draft)
            let outcome = await NotesDocumentCoverService.render(
                document: document, store: store, size: CGSize(width: 320, height: 420),
                maximumSourceBytes: 128 * 1024 * 1024)
            XCTAssertEqual(outcome.source, .quickLookThumbnail,
                           "\(fileExtension) must come from a real Quick Look content representation, not \(outcome.source) (\(outcome.diagnosis))")
            XCTAssertNotNil(outcome.image, "\(fileExtension) cover must be an actual image")
            if let image = outcome.image {
                let attachment = XCTAttachment(image: image)
                attachment.name = "cover-service-\(fileExtension)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// One sample check through the exact production card path: the shared
    /// importer stores the real package at the extensionless Notes CAS path,
    /// the document keeps its original file name, and
    /// `NotesDocumentCoverService` (single-flight + shared host gate) stages one
    /// validated ASCII copy (`preview.<ext>`) before the system Quick Look
    /// generator runs. A cover must be a real Quick Look content image; a
    /// generic icon, the native content summary, `.unsupported` or `.none`
    /// never satisfy this assertion.
    private func assertSampleRenders(_ fileName: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = makeScratchDirectory("quicklook")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        let source = try XCTUnwrap(urls.first { $0.lastPathComponent == fileName }, file: file, line: line)
        let sourceBytes = try Data(contentsOf: source)

        // The app path: import into the Notes store, then read back the exact
        // immutable CAS resource the cover service stages from.
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(draft)
        XCTAssertEqual(document.kind, .office, "\(fileName) must import as an Office document", file: file, line: line)
        XCTAssertEqual(document.officeFileName, fileName,
                       "the original file name must survive import", file: file, line: line)
        let resourceID = try XCTUnwrap(document.officeResourceID, file: file, line: line)
        let resource = try await store.resourceURL(resourceID)
        XCTAssertTrue(resource.pathExtension.isEmpty,
                      "the Notes resource must stay at the extensionless CAS path", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: resource), sourceBytes,
                       "the cover source must be the exact generated package", file: file, line: line)

        let started = ContinuousClock.now
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: CGSize(width: 320, height: 420),
            maximumSourceBytes: 128 * 1024 * 1024)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(outcome.source, .quickLookThumbnail,
                       "\(fileName) must come from a real Quick Look content representation, not \(outcome.source) (\(outcome.diagnosis))",
                       file: file, line: line)
        let image = try XCTUnwrap(outcome.image, file: file, line: line)
        XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
        XCTAssertGreaterThan(image.size.height, 0, file: file, line: line)
        XCTAssertNotNil(image.cgImage, file: file, line: line)
        let diagnostics = try XCTUnwrap(outcome.diagnostics, file: file, line: line)
        XCTAssertFalse(diagnostics.quickLookWasIconFallback,
                       "\(fileName) returned a generic file icon, not content", file: file, line: line)
        XCTAssertFalse(diagnostics.quickLookTimedOut,
                       "\(fileName) must settle with content, not the request deadline", file: file, line: line)
        XCTAssertGreaterThanOrEqual(diagnostics.quickLookAttempts, 1, file: file, line: line)

        let attachment = XCTAttachment(image: image)
        attachment.name = "quicklook-thumbnail-\(fileName)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let evidence = XCTAttachment(string: "fileName=\(fileName) source=\(outcome.source.rawValue) diagnostics=\(diagnostics.summary) elapsed=\(elapsed) casBytes=\(sourceBytes.count)")
        evidence.name = "quicklook-thumbnail-\(fileName)-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    // MARK: - Icon rejection and bounded fallback

    func testContentRepresentationRejectsIconOnly() {
        XCTAssertFalse(NotesOfficeThumbnailGenerator.isContentRepresentation(.icon))
        XCTAssertTrue(NotesOfficeThumbnailGenerator.isContentRepresentation(.thumbnail))
        XCTAssertTrue(NotesOfficeThumbnailGenerator.isContentRepresentation(.lowQualityThumbnail))
    }

    /// An icon-only representation is terminal: it is never returned as a
    /// cover, it is not retried, and the outcome records the fallback so a
    /// caller can decide on a real alternative.
    func testIconOnlyRepresentationIsNotReturnedAndIsNotRetried() async {
        var calls = 0
        let outcome = await NotesOfficeThumbnailGenerator.thumbnail(
            url: URL(fileURLWithPath: "/nonexistent/preview.docx"),
            size: CGSize(width: 320, height: 420),
            fileExtension: "docx",
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: UIImage(systemName: "doc"), diagnosis: "generic icon representation",
                    timedOut: false, elapsed: .zero, isIconFallback: true)
            })
        XCTAssertNil(outcome.image, "an icon must never be returned as content")
        XCTAssertTrue(outcome.wasIconFallback)
        XCTAssertEqual(calls, 1, "an unsupported generator must not be retried")
        XCTAssertEqual(outcome.attempts, 1)
    }

    /// The native OOXML content summary must render a real image from the
    /// document's own parsed text/cells. This is the feasible alternative when
    /// the system has no content generator, and it is explicitly not the
    /// original Office layout.
    func testNativeContentSummaryRendersRealWordAndExcelContent() async throws {
        let root = makeScratchDirectory("summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))

        let wordURL = try XCTUnwrap(urls.first { $0.pathExtension == "docx" })
        let wordSnapshot = try OfficeDocumentService.inspect(url: wordURL)
        let word = try XCTUnwrap(NotesDocumentCoverService.contentSummary(
            snapshot: wordSnapshot, kind: .word, size: CGSize(width: 320, height: 420)))
        XCTAssertNotNil(word.cgImage)
        XCTAssertNotEqual(averageColor(of: word), .clear, "the Word summary must draw real pixels")

        let excelURL = try XCTUnwrap(urls.first { $0.pathExtension == "xlsx" })
        let excelSnapshot = try OfficeDocumentService.inspect(url: excelURL)
        let excel = try XCTUnwrap(NotesDocumentCoverService.contentSummary(
            snapshot: excelSnapshot, kind: .workbook, size: CGSize(width: 320, height: 420)))
        XCTAssertNotNil(excel.cgImage)
        // The header band is a fixed accent in the summary renderer; its
        // presence proves the workbook cells were drawn, not a static glyph.
        let accent = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)
        XCTAssertTrue(containsColor(excel, closeTo: accent, tolerance: 0.08),
                      "the Excel summary header band must show the renderer's real content")
    }

    // MARK: - Extensionless CAS + forced Quick Look failure fallback

    /// The Notes store keeps an imported Office resource at an extensionless
    /// SHA-256 CAS path, and the product summary fallback must read that same
    /// validated staged copy after Quick Look produced no content. These tests
    /// force the Quick Look branch to fail and assert a real native content
    /// summary for each OOXML type, comparing it with a separate summary
    /// render of the original package. This checks CAS routing and source
    /// equivalence; it is not an independent test of renderer quality. This is deliberately separate from the
    /// strict Quick Look-only acceptance above: a summary is a legitimate
    /// product fallback, but it is not the original Office thumbnail.
    func testContentSummaryFallbackRendersWordFromExtensionlessCASWhenQuickLookFails() async throws {
        try await assertContentSummaryFallback(fileName: "商务周报.docx", fileExtension: "docx")
    }

    func testContentSummaryFallbackRendersExcelFromExtensionlessCASWhenQuickLookFails() async throws {
        try await assertContentSummaryFallback(fileName: "季度数据汇总.xlsx", fileExtension: "xlsx")
    }

    func testContentSummaryFallbackRendersPowerPointFromExtensionlessCASWhenQuickLookFails() async throws {
        try await assertContentSummaryFallback(fileName: "产品路线图.pptx", fileExtension: "pptx")
    }

    /// A Quick Look failure on a format the native OOXML inspector cannot read
    /// reports the unsupported-type fallback stage (never a parse or draw
    /// failure) and still publishes no placeholder pixels.
    func testUnsupportedOfficeFormatReportsUnsupportedTypeStage() async throws {
        let root = makeScratchDirectory("cas-unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        // The scratch directory helper only returns a URL; the atomic write
        // below fails with NSCocoaErrorDomain 4/3 if the parent does not exist.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("legacy.rtf")
        try "{\\rtf1\\ansi\\deff0 synthetic legacy document}".write(to: source, atomically: true, encoding: .utf8)

        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(draft)
        XCTAssertEqual(document.kind, .office)
        XCTAssertEqual(document.officeFileName, "legacy.rtf")

        let forcedFailure: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome) = { _, _, _ in
            NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: "injected quick look failure", timedOut: false,
                elapsed: .zero, errorDomain: "QLThumbnailErrorDomain", errorCode: 102)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: CGSize(width: 320, height: 420),
            maximumSourceBytes: 128 * 1024 * 1024, request: forcedFailure)
        XCTAssertEqual(outcome.source, .unsupported)
        XCTAssertNil(outcome.image, "an unsupported format must never publish placeholder pixels")
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertEqual(diagnostics.fallbackStage, .unsupportedType,
                       "a non-OOXML format must be reported as unsupported type, not parsed: \(diagnostics.summary)")
        XCTAssertEqual(diagnostics.quickLookAttempts, 3)
        XCTAssertFalse(diagnostics.summary.isEmpty)
    }

    /// `other` is the only permitted substitution for an unknown error domain,
    /// so a hostile or path-bearing domain can never leak identifying text
    /// into an artifact or the UI-test accessibility value.
    func testDiagnosticsRedactUnknownAndHostileErrorDomains() {
        for known in ["QLThumbnailErrorDomain", "QLThumbnailGenerationErrorDomain",
                      "NSCocoaErrorDomain", "NSPOSIXErrorDomain",
                      "NSURLErrorDomain", "NSOSStatusErrorDomain"] {
            XCTAssertEqual(NotesDocumentCoverDiagnostics.boundedDomain(known), known,
                           "known system domain \(known) must be preserved")
        }
        XCTAssertEqual(NotesDocumentCoverDiagnostics.boundedDomain("com.apple.quicklook.private"), "other")
        XCTAssertEqual(NotesDocumentCoverDiagnostics.boundedDomain("/Users/someone/Documents/secret.docx"), "other")
        XCTAssertEqual(NotesDocumentCoverDiagnostics.boundedDomain("张三的私人文件夹"), "other")
        XCTAssertEqual(NotesDocumentCoverDiagnostics.boundedDomain("SecretDomainWithNoPunctuation"), "other")
        XCTAssertNil(NotesDocumentCoverDiagnostics.boundedDomain(nil))
        XCTAssertNil(NotesDocumentCoverDiagnostics.boundedDomain(""))

        var diagnostics = NotesDocumentCoverDiagnostics()
        diagnostics.quickLookErrorDomain = NotesDocumentCoverDiagnostics.boundedDomain("/Users/someone")
        diagnostics.quickLookErrorCode = 1
        XCTAssertEqual(diagnostics.quickLookErrorDomain, "other")
        XCTAssertFalse(diagnostics.summary.contains("someone"))
        XCTAssertFalse(diagnostics.summary.contains("/"))
    }

    private func assertContentSummaryFallback(fileName: String, fileExtension: String,
                                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = makeScratchDirectory("cas-fallback-\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == fileName }, file: file, line: line)
        let originalBytes = try Data(contentsOf: url)

        // Import through the same path the app uses, then prove the stored
        // resource really is the extensionless CAS path Quick Look cannot read.
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
        let document = try await store.create(draft)
        let resourceID = try XCTUnwrap(document.officeResourceID, file: file, line: line)
        let resource = try await store.resourceURL(resourceID)
        XCTAssertTrue(resource.pathExtension.isEmpty,
                      "the Notes resource must stay at the extensionless CAS path", file: file, line: line)

        // The expected content cover is a separate summary render of the
        // original package as inspected by the shared Office service. The
        // fallback must reproduce that full content render, not just a color.
        let coverSize = CGSize(width: 320, height: 420)
        let expectedSnapshot = try OfficeDocumentService.inspect(url: url)
        XCTAssertFalse(expectedSnapshot.fields.isEmpty,
                       "\(fileExtension) fixture must expose real inspectable content", file: file, line: line)
        let expectedImage = try XCTUnwrap(NotesDocumentCoverService.contentSummary(
            snapshot: expectedSnapshot, kind: expectedSnapshot.kind, size: coverSize),
            "\(fileExtension) expected summary image must render", file: file, line: line)

        // Force the "system generator produced no content" branch for this one
        // render through the per-call seam. The injected closure also observes
        // the real staged Quick Look input: an extension-carrying, byte-exact
        // copy of the immutable resource while Quick Look runs.
        var observedStagedURL: URL?
        var observedStagedBytesMatch = false
        let forcedFailure: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome) = { staged, _, _ in
            observedStagedURL = staged
            observedStagedBytesMatch = (try? Data(contentsOf: staged)) == originalBytes
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: "injected quick look failure", timedOut: false,
                elapsed: .zero, errorDomain: "QLThumbnailErrorDomain", errorCode: 102)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: 128 * 1024 * 1024, request: forcedFailure)

        XCTAssertEqual(outcome.source, .officeContentSummary,
                       "\(fileExtension) must fall back to the native content summary, got \(outcome.source) (\(outcome.diagnosis))",
                       file: file, line: line)
        let image = try XCTUnwrap(outcome.image, "\(fileExtension) summary must be an actual image",
                                  file: file, line: line)
        XCTAssertNotNil(image.cgImage, file: file, line: line)
        assertSameRenderedContent(image, expectedImage, label: fileExtension, file: file, line: line)

        // The staged copy must carry the validated extension, contain the
        // exact document bytes while the request runs, and be removed with its
        // staging directory once the render settles.
        let staged = try XCTUnwrap(observedStagedURL,
                                   "the Quick Look request must receive the staged copy", file: file, line: line)
        XCTAssertTrue(observedStagedBytesMatch,
                      "the staged copy must be the exact document bytes", file: file, line: line)
        XCTAssertEqual(staged.lastPathComponent, "preview.\(fileExtension)", file: file, line: line)
        XCTAssertEqual(staged.pathExtension, fileExtension, file: file, line: line)
        XCTAssertTrue(staged.deletingLastPathComponent().lastPathComponent.hasPrefix("floe-notes-thumb-"),
                      "staging must use the product staging directory", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "the staged Quick Look copy must be removed after the render", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path),
                       "the staging directory must be removed after the render", file: file, line: line)

        // Bounded, redacted failure identity for the artifact.
        let diagnostics = try XCTUnwrap(outcome.diagnostics, file: file, line: line)
        XCTAssertEqual(diagnostics.quickLookAttempts, 3, file: file, line: line)
        XCTAssertFalse(diagnostics.quickLookTimedOut, file: file, line: line)
        XCTAssertEqual(diagnostics.quickLookErrorDomain, "QLThumbnailErrorDomain", file: file, line: line)
        XCTAssertEqual(diagnostics.quickLookErrorCode, 102, file: file, line: line)
        XCTAssertFalse(diagnostics.quickLookWasIconFallback, file: file, line: line)
        XCTAssertEqual(diagnostics.fallbackStage, .quickLook,
                       "the failure originates in the Quick Look stage; the summary then succeeded",
                       file: file, line: line)
        XCTAssertFalse(diagnostics.summary.contains(fileName),
                       "diagnostics must never carry a file name", file: file, line: line)
        XCTAssertFalse(diagnostics.summary.contains("/"),
                       "diagnostics must never carry a path", file: file, line: line)
        XCTAssertFalse(diagnostics.summary.isEmpty, file: file, line: line)
        // Match the bounded schema exactly: short spreadsheet cells may
        // legitimately coincide with the numeric error code or attempt count.
        XCTAssertEqual(diagnostics.summary,
                       "attempts=3 timedOut=false domain=QLThumbnailErrorDomain code=102 fallback=quickLook",
                       "diagnostics contain only the expected system identity", file: file, line: line)

        let attachment = XCTAttachment(image: image)
        attachment.name = "cas-summary-fallback-\(fileExtension)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let evidence = XCTAttachment(string: "source=\(outcome.source.rawValue) diagnostics=\(diagnostics.summary) staged=\(staged.lastPathComponent) stagedRemoved=true")
        evidence.name = "cas-summary-fallback-\(fileExtension)-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    /// Both images are separate `contentSummary` renders of the same
    /// package at the same size. They must be the same pixels; only sub-pixel
    /// antialiasing noise may differ, and never more than a strict bound.
    private func assertSameRenderedContent(_ image: UIImage, _ expected: UIImage, label: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.size, expected.size, "\(label) summary size must match", file: file, line: line)
        guard let actualData = image.pngData(), let expectedData = expected.pngData() else {
            XCTFail("\(label) summary must encode to PNG", file: file, line: line)
            return
        }
        if actualData == expectedData { return }
        guard let actual = image.cgImage, let reference = expected.cgImage,
              actual.width == reference.width, actual.height == reference.height else {
            XCTFail("\(label) summary must match the original file's content render", file: file, line: line)
            return
        }
        let width = actual.width, height = actual.height
        var actualPixels = [UInt8](repeating: 0, count: width * height * 4)
        var expectedPixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let actualContext = CGContext(data: &actualPixels, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let expectedContext = CGContext(data: &expectedPixels, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) else {
            XCTFail("\(label) summary pixel buffers must be readable", file: file, line: line)
            return
        }
        actualContext.draw(actual, in: CGRect(x: 0, y: 0, width: width, height: height))
        expectedContext.draw(reference, in: CGRect(x: 0, y: 0, width: width, height: height))
        var mismatched = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            if abs(Int(actualPixels[index]) - Int(expectedPixels[index])) > 2
                || abs(Int(actualPixels[index + 1]) - Int(expectedPixels[index + 1])) > 2
                || abs(Int(actualPixels[index + 2]) - Int(expectedPixels[index + 2])) > 2 {
                mismatched += 1
            }
        }
        let total = width * height
        XCTAssertLessThanOrEqual(Double(mismatched) / Double(max(total, 1)), 0.001,
                                 "\(label) summary (\(mismatched)/\(total) mismatched pixels) must render the original package's content",
                                 file: file, line: line)
    }

    // MARK: - Mind-map cover structure

    func testMindMapCoverIsAStructuredBoundedNodeTree() throws {
        let root = MindMapNode(title: "中心主题")
        let a = MindMapNode(parentID: root.id, title: "分支 A", order: 0)
        let b = MindMapNode(parentID: root.id, title: "分支 B", order: 1)
        let a1 = MindMapNode(parentID: a.id, title: "子节点", order: 0)
        // A real cross-link (not a parent/child edge) must survive as an edge.
        let cross = MindMapConnection(from: b.id, to: a1.id, title: "跨链接")
        let layout = NotesDocumentCoverService.mindMapLayout(
            nodes: [b, a1, root, a], connections: [cross], maximumRows: 40)
        XCTAssertEqual(layout.rows.first?.title, "中心主题")
        XCTAssertEqual(layout.rows.first?.depth, 0)
        // Order must be stable by `order`, not by array position.
        XCTAssertEqual(Array(layout.rows.dropFirst().map(\.title)), ["分支 A", "子节点", "分支 B"])
        XCTAssertEqual(Array(layout.rows.dropFirst().map(\.depth)), [1, 2, 1])
        XCTAssertLessThanOrEqual(layout.rows.count, 40)
        XCTAssertEqual(layout.edges.count, 1, "the explicit cross-link must be rendered as an edge")
        XCTAssertEqual(layout.edges.first?.title, "跨链接")
    }

    // MARK: - Engineering covers (real DXF/DWG through the bundled viewer)

    /// The offscreen renderer must paint the bundled DXF sample's own geometry
    /// through the real viewer and return non-background pixels. A blank
    /// offscreen canvas (a `toDataURL` that only proves the canvas exists) or a
    /// generic icon must not satisfy this.
    func testOffscreenRendererPaintsRealDxfGeometry() async throws {
        try await assertOffscreenRendererPaints(fileName: "sample-plate.dxf", fileExtension: "dxf")
    }

    /// DWG is converted by the bundled CAD engine before rendering, so it is a
    /// separate decode path from DXF.
    func testOffscreenRendererPaintsRealDwgGeometry() async throws {
        try await assertOffscreenRendererPaints(fileName: "sample-editable.dwg", fileExtension: "dwg")
    }

    private func assertOffscreenRendererPaints(fileName: String, fileExtension: String,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = try engineeringSampleURL(fileName, file: file, line: line)
        let outcome = await NotesEngineeringCoverRenderer.shared.thumbnail(
            source: source, fileName: fileName, fileExtension: fileExtension,
            size: CGSize(width: 320, height: 420))
        let image = try XCTUnwrap(outcome.image,
                                  "\(fileName) must render real pixels, not a placeholder: \(outcome.diagnosis)",
                                  file: file, line: line)
        XCTAssertEqual(outcome.diagnosis, "bundled viewer", file: file, line: line)
        let geometry = nonBackgroundPixelCount(in: image)
        XCTAssertGreaterThanOrEqual(geometry, 8,
                                    "\(fileName) cover must contain non-background drawing pixels, found \(geometry)",
                                    file: file, line: line)
        let attachment = XCTAttachment(image: image)
        attachment.name = "engineering-render-\(fileExtension)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The unified cover service must route real DXF and DWG documents to the
    /// bundled viewer (`.engineeringPreview`), never to the unsupported
    /// placeholder or a generic icon.
    func testCoverServiceRendersDxfAndDwgThroughBundledViewer() async throws {
        let root = makeScratchDirectory("engineering")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        for (fileName, fileExtension) in [("sample-plate.dxf", "dxf"), ("sample-editable.dwg", "dwg")] {
            let source = try engineeringSampleURL(fileName)
            let staged = root.appendingPathComponent(fileName)
            try Data(contentsOf: source).write(to: staged, options: .atomic)
            let draft = try await NoteFileImporter.importFile(staged, notebookID: nil, store: store)
            let document = try await store.create(draft)
            XCTAssertEqual(document.kind, .engineering)
            let outcome = await NotesDocumentCoverService.render(
                document: document, store: store, size: CGSize(width: 320, height: 420),
                maximumSourceBytes: 128 * 1024 * 1024)
            XCTAssertEqual(outcome.source, .engineeringPreview,
                           "\(fileName) must come from the bundled viewer, not \(outcome.source) (\(outcome.diagnosis))")
            let image = try XCTUnwrap(outcome.image, "\(fileName) cover must be an actual image")
            XCTAssertGreaterThanOrEqual(nonBackgroundPixelCount(in: image), 8,
                                        "\(fileName) cover must contain non-background drawing pixels")
            let attachment = XCTAttachment(image: image)
            attachment.name = "cover-service-\(fileExtension)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// A real store save (rename) must commit a new revision while the
    /// immutable engineering resource stays renderable, so the revision-keyed
    /// card reload cannot be satisfied by a stale cover.
    func testEngineeringCoverRerendersAfterRenameRevision() async throws {
        let root = makeScratchDirectory("engineering-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let source = try engineeringSampleURL("sample-plate.dxf")
        let staged = root.appendingPathComponent("sample-plate.dxf")
        try Data(contentsOf: source).write(to: staged, options: .atomic)
        let draft = try await NoteFileImporter.importFile(staged, notebookID: nil, store: store)
        let document = try await store.create(draft)
        let first = await NotesDocumentCoverService.render(
            document: document, store: store, size: CGSize(width: 320, height: 420),
            maximumSourceBytes: 128 * 1024 * 1024)
        XCTAssertEqual(first.source, .engineeringPreview)

        let renamed = try await store.apply(.init(
            documentID: document.id, expectedRevision: document.revision,
            title: "重命名图纸", edits: [.rename("重命名图纸")]))
        XCTAssertGreaterThan(renamed.revision, document.revision,
                             "a rename must advance the document revision")
        XCTAssertEqual(renamed.engineeringResourceID, document.engineeringResourceID,
                       "renaming must not replace the immutable drawing resource")

        let second = await NotesDocumentCoverService.render(
            document: renamed, store: store, size: CGSize(width: 320, height: 420),
            maximumSourceBytes: 128 * 1024 * 1024)
        XCTAssertEqual(second.source, .engineeringPreview,
                       "the renamed revision must still render from the bundled viewer")
    }

    /// Resolves a bundled engineering sample from the host app resources. The
    /// NativeNotes qualification host bundles `EngineeringViewers`; a unit test
    /// must fail, not silently skip, if that resource is missing.
    private func engineeringSampleURL(_ fileName: String, file: StaticString = #filePath,
                                      line: UInt = #line) throws -> URL {
        let directory = try XCTUnwrap(
            Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
            "the qualification host must bundle EngineeringViewers", file: file, line: line)
        let url = directory.appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "missing bundled sample \(fileName)", file: file, line: line)
        return url
    }

    /// Counts pixels that differ from the viewer's light clear color
    /// (`#f5f6f8`). A blank canvas is a single uniform color and yields zero;
    /// real line work yields many.
    private func nonBackgroundPixelCount(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let background = (red: 245.0 / 255, green: 246.0 / 255, blue: 248.0 / 255)
        let tolerance = 0.08 * 255
        var count = 0
        for y in stride(from: 0, to: height, by: max(1, height / 96)) {
            for x in stride(from: 0, to: width, by: max(1, width / 96)) {
                let offset = (y * width + x) * 4
                let red = Double(pixels[offset]), green = Double(pixels[offset + 1]), blue = Double(pixels[offset + 2])
                if abs(red - background.red * 255) > tolerance
                    || abs(green - background.green * 255) > tolerance
                    || abs(blue - background.blue * 255) > tolerance {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Helpers

    private func averageColor(of image: UIImage) -> UIColor {
        guard let cgImage = image.cgImage else { return .clear }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .clear }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
    }

    /// Samples a small grid of pixels and reports whether any is close to the
    /// expected color. It tolerates QL/renderer antialiasing without accepting
    /// an unrelated image.
    private func containsColor(_ image: UIImage, closeTo expected: UIColor, tolerance: CGFloat) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var expectedRed: CGFloat = 0, expectedGreen: CGFloat = 0, expectedBlue: CGFloat = 0, expectedAlpha: CGFloat = 0
        guard expected.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha) else { return false }
        for y in stride(from: 0, to: height, by: max(1, height / 24)) {
            for x in stride(from: 0, to: width, by: max(1, width / 24)) {
                let offset = (y * width + x) * 4
                let red = CGFloat(pixels[offset]) / 255
                let green = CGFloat(pixels[offset + 1]) / 255
                let blue = CGFloat(pixels[offset + 2]) / 255
                if abs(red - expectedRed) <= tolerance, abs(green - expectedGreen) <= tolerance,
                   abs(blue - expectedBlue) <= tolerance { return true }
            }
        }
        return false
    }
}
