// SPDX-License-Identifier: MPL-2.0
//
// Targeted checks for the `--preview-fixture` Office thumbnail qualification
// host. They assert that the fixtures are real, inspectable OOXML packages and
// that the same files `NotesDocumentThumbnail` would stage are rendered by the
// shared bounded product generator (`NotesOfficeThumbnailGenerator`), not by
// a test-only request path: identical per-attempt timeout, retry count,
// backoff, total deadline and diagnostics. They do not modify product code.
//
// The six render checks are independent tests so a CI run never spends more
// than one bounded card request (~45s worst case) per test method. The
// qualification runner is known to ship an Office Quick Look generator, so a
// failure is a failure — there is no all-fail skip left to mask a regression.
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

    // MARK: - Quick Look render checks (one independent test per sample)

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

    /// The view stages a copy with a validated extension and asks Quick Look
    /// for a real representation through the shared bounded retry path. Each
    /// check stages the same copies and calls the exact same
    /// `NotesOfficeThumbnailGenerator.thumbnail` policy the product grid uses,
    /// so a transient first-attempt failure (such as the hypothesised
    /// cold-start generator launch race) may be recovered by identical retry
    /// behaviour instead of a divergent test-only path. A returned image must
    /// be non-empty and is attached with `.keepAlways` so the result bundle
    /// carries the actual generator output for review. The fixtures are
    /// synthetic OOXML, so a hand-drawn or placeholder image must never be
    /// attached in its place.
    private func assertSampleRenders(_ fileName: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = makeScratchDirectory("quicklook")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == fileName }, file: file, line: line)

        switch await Self.quickLookThumbnail(for: url) {
        case .success(let image):
            XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
            XCTAssertGreaterThan(image.size.height, 0, file: file, line: line)
            XCTAssertNotNil(image.cgImage, file: file, line: line)
            // Keep the actual Quick Look output for this generated package.
            // Nothing is synthesized here: an attachment only exists when the
            // system generator returned a real representation.
            let attachment = XCTAttachment(image: image)
            attachment.name = "quicklook-thumbnail-\(url.lastPathComponent)"
            attachment.lifetime = .keepAlways
            add(attachment)
        case .failure(let failure):
            XCTFail("Quick Look failed to render \(url.lastPathComponent): \(failure)", file: file, line: line)
        }
    }

    /// Mirrors `NotesDocumentThumbnail` staging: Quick Look needs the validated
    /// extension, so a uniquely scoped copy is requested instead of the CAS path.
    /// The bounded request itself runs through the shared product generator —
    /// identical timeout, retry count, backoff and total deadline — and reports
    /// the per-attempt diagnosis on failure for log triage.
    private enum ThumbnailFailure: Error, CustomStringConvertible {
        case staging(String)
        case generator(NotesOfficeThumbnailGenerator.CardOutcome)

        var description: String {
            switch self {
            case .staging(let detail): return detail
            case .generator(let outcome):
                return "attempts=\(outcome.attempts) elapsed=\(outcome.elapsed) diagnosis=\(outcome.diagnosis)"
            }
        }
    }

    private static func quickLookThumbnail(for source: URL,
                                           size: CGSize = CGSize(width: 320, height: 420)) async -> Result<UIImage, ThumbnailFailure> {
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
        if let image = outcome.image { return .success(image) }
        return .failure(.generator(outcome))
    }
}
