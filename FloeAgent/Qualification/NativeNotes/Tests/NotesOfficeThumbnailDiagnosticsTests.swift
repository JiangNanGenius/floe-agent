// SPDX-License-Identifier: MPL-2.0
//
// STRICT Quick Look-only diagnostics for the Notes Office covers.
//
// Per the root acceptance decision this class is excluded from the functional
// component run (`-skip-testing:NativeNotesTests/NotesOfficeThumbnailDiagnosticsTests`)
// and executed by `notes-native-qualification.yml` as a separate, explicitly
// non-gating diagnostic step with its own `notes-diagnostic-<family>.xcresult`,
// log and original exit code. It asserts the original strict contract: every
// Office sample and every Office type must settle as a real system Quick Look
// content representation. A failure here is a recorded system-host diagnostic;
// it is never converted into a pass and never silently deleted. The two-tier
// functional acceptance (real Quick Look content OR the explicitly labeled
// native summary) lives in `NotesOfficeThumbnailTests`.
//
// Classification contract consumed by
// `FloeAgent/scripts/verify_quicklook_diagnostics.py`: only the three explicit
// system-Quick-Look-unavailability assertions carry a fixed marker — a missing
// content representation (`:content`), a request deadline (`:timeout`) and a
// generic file icon (`:icon`). Every other assertion (image presence/size,
// diagnostics presence, resource invariants) is deliberately unmarked, so an
// unexpected error, throw, crash or a wrong document can never be classified
// as a permitted Quick Look outage.
import XCTest
import UIKit
import FloeNotes
import FloeDocuments
@testable import FloeNotesNativeQualification

@MainActor
final class NotesOfficeThumbnailDiagnosticsTests: XCTestCase {
    /// Fixed markers consumed by the Python classifier. Do not change them
    /// without updating `verify_quicklook_diagnostics.py` and its fixtures.
    private enum QuickLookDiagnosticMarker {
        static let content = "[floe-ql-diagnostic:content]"
        static let timeout = "[floe-ql-diagnostic:timeout]"
        static let icon = "[floe-ql-diagnostic:icon]"
    }

    private func makeScratchDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-office-diagnostic-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Strict per-sample diagnostics (preserved from the original suite)

    func testStrictQuickLookRendersWordBusinessWeekly() async throws {
        try await assertStrictSampleRenders("商务周报.docx")
    }

    func testStrictQuickLookRendersWordMeetingNotes() async throws {
        try await assertStrictSampleRenders("meeting-notes.docx")
    }

    func testStrictQuickLookRendersExcelQuarterlySummary() async throws {
        try await assertStrictSampleRenders("季度数据汇总.xlsx")
    }

    func testStrictQuickLookRendersExcelBudgetForecast() async throws {
        try await assertStrictSampleRenders("budget-forecast.xlsx")
    }

    func testStrictQuickLookRendersPowerPointProductRoadmap() async throws {
        try await assertStrictSampleRenders("产品路线图.pptx")
    }

    func testStrictQuickLookRendersPowerPointDesignReview() async throws {
        try await assertStrictSampleRenders("design-review.pptx")
    }

    /// The unified cover service must return a real Quick Look thumbnail source
    /// (not `.unsupported`, not `.officeContentSummary`) for every Office type
    /// imported through the same `NoteFileImporter` path the app uses. This is
    /// the mechanism-level check that a generic file icon can never satisfy.
    func testCoverServiceReturnsQuickLookContentForEachOfficeType() async throws {
        // This case renders three Office formats sequentially, each under the
        // product's 45 s bounded Quick Look budget: a fully unavailable system
        // host costs up to 3 x 45 s = 135 s, above the workflow's default 120 s
        // allowance. Raise this one case to the workflow's existing 180 s
        // maximum; all assertions and the global 90/180 defaults stay as they
        // are, and no other case gets a wider bound.
        executionTimeAllowance = 180
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
                           "\(fileExtension) must come from a real Quick Look content representation, not \(outcome.source) (\(outcome.diagnosis)) \(QuickLookDiagnosticMarker.content)")
            XCTAssertNotNil(outcome.image, "\(fileExtension) cover must be an actual image")
            if let image = outcome.image {
                let attachment = XCTAttachment(image: image)
                attachment.name = "cover-service-\(fileExtension)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// One strict sample check through the exact production card path. A cover
    /// must be a real Quick Look content image; the native content summary,
    /// `.unsupported` and `.none` do not satisfy this diagnostic.
    private func assertStrictSampleRenders(_ fileName: String, file: StaticString = #filePath,
                                           line: UInt = #line) async throws {
        let root = makeScratchDirectory("quicklook")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        let source = try XCTUnwrap(urls.first { $0.lastPathComponent == fileName }, file: file, line: line)
        let sourceBytes = try Data(contentsOf: source)

        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(draft)
        let started = ContinuousClock.now
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: CGSize(width: 320, height: 420),
            maximumSourceBytes: 128 * 1024 * 1024)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(outcome.source, .quickLookThumbnail,
                       "\(fileName) must come from a real Quick Look content representation, not \(outcome.source) (\(outcome.diagnosis)) \(QuickLookDiagnosticMarker.content)",
                       file: file, line: line)
        let image = try XCTUnwrap(outcome.image, file: file, line: line)
        XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
        XCTAssertGreaterThan(image.size.height, 0, file: file, line: line)
        XCTAssertNotNil(image.cgImage, file: file, line: line)
        let diagnostics = try XCTUnwrap(outcome.diagnostics, file: file, line: line)
        XCTAssertFalse(diagnostics.quickLookWasIconFallback,
                       "\(fileName) returned a generic file icon, not content \(QuickLookDiagnosticMarker.icon)", file: file, line: line)
        XCTAssertFalse(diagnostics.quickLookTimedOut,
                       "\(fileName) must settle with content, not the request deadline \(QuickLookDiagnosticMarker.timeout)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(diagnostics.quickLookAttempts, 1, file: file, line: line)

        let attachment = XCTAttachment(image: image)
        attachment.name = "strict-quicklook-thumbnail-\(fileName)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let evidence = XCTAttachment(string: "fileName=\(fileName) source=\(outcome.source.rawValue) diagnostics=\(diagnostics.summary) elapsed=\(elapsed) casBytes=\(sourceBytes.count)")
        evidence.name = "strict-quicklook-thumbnail-\(fileName)-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
