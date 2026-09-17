// SPDX-License-Identifier: MPL-2.0
//
// Targeted checks for the Notes unified library-cover mechanism and the
// `--preview-fixture` Office thumbnail qualification host.
//
// They assert that:
//  * the fixtures are real, inspectable OOXML packages that the shared importer
//    accepts as `.office` documents pointing at an intact CAS resource;
//  * Quick Look output is real document content, never a generic file icon;
//  * the shared `NotesDocumentCoverService` returns a `.quickLookThumbnail`
//    source for real Word/Excel/PPT packages;
//  * when Quick Look only offers an icon, the bounded generator stops, reports
//    the icon fallback and never returns it as content;
//  * the bounded native OOXML content-summary fallback renders a real image
//    from the document's own text/cells;
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

    /// The view stages a copy with a validated extension and asks Quick Look
    /// for a real representation through the shared bounded retry path. A
    /// returned image must be non-empty and must not be the generic file-type
    /// icon; the actual generator output is attached with `.keepAlways`.
    private func assertSampleRenders(_ fileName: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = makeScratchDirectory("quicklook")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == fileName }, file: file, line: line)

        switch await Self.quickLookThumbnail(for: url) {
        case .success(let outcome):
            let image = try XCTUnwrap(outcome.image, file: file, line: line)
            XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
            XCTAssertGreaterThan(image.size.height, 0, file: file, line: line)
            XCTAssertNotNil(image.cgImage, file: file, line: line)
            XCTAssertFalse(outcome.wasIconFallback,
                           "\(url.lastPathComponent) returned a generic file icon, not content", file: file, line: line)
            let attachment = XCTAttachment(image: image)
            attachment.name = "quicklook-thumbnail-\(url.lastPathComponent)"
            attachment.lifetime = .keepAlways
            add(attachment)
        case .failure(let failure):
            XCTFail("Quick Look failed to render \(url.lastPathComponent): \(failure)", file: file, line: line)
        }
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

    private enum ThumbnailFailure: Error, CustomStringConvertible {
        case staging(String)
        case generator(NotesOfficeThumbnailGenerator.CardOutcome)

        var description: String {
            switch self {
            case .staging(let detail): return detail
            case .generator(let outcome):
                return "attempts=\(outcome.attempts) elapsed=\(outcome.elapsed) diagnosis=\(outcome.diagnosis) iconFallback=\(outcome.wasIconFallback)"
            }
        }
    }

    private static func quickLookThumbnail(for source: URL,
                                           size: CGSize = CGSize(width: 320, height: 420)) async -> Result<NotesOfficeThumbnailGenerator.CardOutcome, ThumbnailFailure> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-office-thumb-stage-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return .failure(.staging("staging directory could not be created: \(error)")) }
        defer { try? FileManager.default.removeItem(at: directory) }

        let copy = directory.appendingPathComponent("preview.\(source.pathExtension.lowercased())")
        do { try FileManager.default.copyItem(at: source, to: copy) } catch { return .failure(.staging("staging copy failed: \(error)")) }

        let outcome = await NotesOfficeThumbnailGenerator.thumbnail(url: copy, size: size,
                                                                    fileExtension: source.pathExtension.lowercased())
        if outcome.image != nil { return .success(outcome) }
        return .failure(.generator(outcome))
    }

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
