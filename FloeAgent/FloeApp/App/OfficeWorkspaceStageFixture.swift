// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import FloeCore
import FloeDocuments
import FloeNotes
import FloePersistence
import FloeWorkspace

/// Debug-only workspace fixture for the cloud simulator Office stage run.
///
/// It generates a real PPTX (title, bullets, a native editable chart and a
/// shape) and a real DOCX through the same OOXML builders the product uses,
/// then writes them into the shared task-root workspace seeded by
/// `--ui-test-batch-fixture`. That lets the Workspace preview, IDE tab and
/// Notes entry paths be driven against real documents without a native
/// engine, and with no test-only control inside the product UI. Gated on
/// `-ui-testing` plus an explicit launch argument; idempotent per install.
///
/// It also seeds one separate, independently owned Notes document for the
/// real-UIKit pinch acceptance (see `seedCenteredPinchDocumentIfRequested`),
/// created through the same `NoteFileImporter` path as a user file import but
/// laid out so its measured line sits around the public gesture anchor
/// instead of the page top-left. The ordinary Notes document creation flow,
/// the Office builders and the product gesture code are untouched.
@MainActor
enum OfficeWorkspaceStageFixture {
    static let launchArgument = "--ui-test-office-workspace-fixture"
    static let deckName = "办公验收-演示.pptx"
    static let wordName = "办公验收-文稿.docx"

    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        let fixtureID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
        do {
            let record = try await SQLiteWorkspaceStore(database: environment.database)
                .ensureWorkspace(conversationID: fixtureID, title: "批量选择测试")
            let lease = try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: fixtureID)
            defer { lease.release() }
            let deck = lease.url.appendingPathComponent(deckName)
            if !FileManager.default.fileExists(atPath: deck.path) {
                try OfficeDocumentBuilder.createPresentation(at: deck, title: "Floe 演示验收", slides: [
                    OfficePresentationSlide(title: "Floe 演示验收", bullets: [
                        "真实 PPTX：首帧、编辑与写回链路",
                        "Cloud iPad simulator stage trace",
                    ], notes: "Simulator host blocker probe"),
                    OfficePresentationSlide(title: "对象与图表", bullets: [
                        "原生可编辑图表",
                        "形状与文本对象",
                    ], objects: [
                        OfficePresentationObject(kind: .shape, layout: .right,
                                                 text: ["形状"],
                                                 shape: .roundedRectangle,
                                                 fillColor: "1F6FEB",
                                                 textColor: "FFFFFF", bold: true),
                        OfficePresentationObject(kind: .chart, layout: .left,
                                                 chart: OfficePresentationChart(
                                                    chartType: .bar,
                                                    title: "季度收入",
                                                    categories: ["Q1", "Q2", "Q3"],
                                                    series: [OfficePresentationChartSeries(
                                                        name: "收入", values: [120, 150, 168])])),
                    ]),
                ])
            }
            let word = lease.url.appendingPathComponent(wordName)
            if !FileManager.default.fileExists(atPath: word.path) {
                try OfficeDocumentBuilder.createWord(at: word, title: "Floe 文稿验收", paragraphs: [
                    "真实 DOCX，用于 DOCX 入口回归。",
                    "DOCX entry regression fixture.",
                ])
            }
        } catch {
            // A fixture failure leaves the pre-existing workspace untouched.
        }
    }

    // MARK: - Centered real-UIKit pinch acceptance document

    /// Real DOCX fixture positioned around the landscape gesture anchor.
    /// Leading spaces indent the complete OCR target onto the anchor's
    /// horizontal centre, and the seven numbered spacer rows above it place
    /// the target about 39% down the landscape canvas from the page top.
    /// The 2026-10-20 keyboard-run evidence measured the reachable pre-pinch
    /// scroll states: the page-top state framed the old target at 10.6% of
    /// the web view (pushed out by an inward pinch about the far-below
    /// anchor pivot), while the hide-keyboard cursor reveal framed it at
    /// ~43%. At 39-44% the complete title stays inside the viewport across
    /// the observed committed scales (1.197x-2.488x) about the canvas-anchor
    /// pivot, with the UI test's growth/shrink thresholds unchanged.
    /// Existing entries, including Trash, are left untouched; the owned
    /// title is versioned (-3) because seeding is idempotent by title and
    /// the shared device may still hold the previous layout.
    static let pinchCenterLaunchArgument = "--ui-test-office-pinch-center-fixture"
    static let pinchCenterDocumentName = "捏合验收-居中-3.docx"
    /// The complete, deterministic OCR target. It is duplicated verbatim in
    /// `NotesWorkspaceImportUITests.officeMeasuredTitleBounds` (the test
    /// target cannot import the app target); keep both in sync. No random
    /// token is needed: identity comes from the owned document, and a fixed
    /// label avoids OCR noise from a changing suffix.
    static let pinchCenterMeasuredText = "Pen UI 5X8KQ2M7"

    static func seedCenteredPinchDocumentIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              arguments.contains(pinchCenterLaunchArgument) else { return }
        do {
            let store = try await NotesRepository.shared.store()
            let ownedTitle = (pinchCenterDocumentName as NSString).deletingPathExtension
            let existing = try await store.documents(includeTrash: true)
            guard !existing.contains(where: { $0.title == ownedTitle }) else { return }
            let scratch = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "notes")
            let root = scratch.url
            defer {
                try? FileManager.default.removeItem(at: root)
                scratch.lease.release()
            }
            let url = root.appendingPathComponent(pinchCenterDocumentName)
            // The measured line is a body paragraph: the 26 pt Title line is
            // the first paragraph by construction and would sit at the page
            // top (the geometry the original diagnosis documented).
            let measured = String(repeating: " ", count: 44) + pinchCenterMeasuredText
            try OfficeDocumentBuilder.createWord(at: url, title: "Pinch Center Anchor", paragraphs: [
                "Centered UIKit pinch acceptance fixture.",
                "anchor spacer row one",
                "anchor spacer row two",
                "anchor spacer row three",
                "anchor spacer row four",
                "anchor spacer row five",
                "anchor spacer row six",
                "anchor spacer row seven",
                measured,
                "anchor footer row one",
                "anchor footer row two",
            ])
            let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
            _ = try await store.create(draft)
        } catch {
            // A fixture failure leaves the pre-existing library untouched; the
            // acceptance test then fails honestly on its own visibility gate.
        }
    }

    // MARK: - Centered real-UIKit pinch: Calc and Impress fixtures

    /// Real XLSX fixture for the strict centered real-UIKit acceptance. The
    /// measured line sits in cell G10 so the complete OCR target stays inside
    /// the landscape viewport at the committed pinch scales. Calc applies no
    /// fit-to-window zoom in the pinned engine (Writer alone gets a dynamic
    /// fit), so it starts at the same default zoom 10 measured for the Word
    /// fixture; the placement was swept across default header/column/row
    /// metrics at that zoom. A calc fixture failure is a placement signal, not
    /// a threshold signal.
    static let pinchCenterCalcLaunchArgument = "--ui-test-office-pinch-center-calc-fixture"
    static let pinchCenterCalcDocumentName = "捏合验收-居中-表格-2.xlsx"
    /// The complete, deterministic OCR target for the Calc case. Duplicated
    /// verbatim in `NotesWorkspaceImportUITests` (the test target cannot import
    /// the app target); keep both in sync.
    static let pinchCenterCalcMeasuredText = "Pen UI 7C3MV1K9"

    /// Real PPTX fixture for the strict centered real-UIKit acceptance. The
    /// deck is one 16:9 slide whose measurement text object is centred on the
    /// slide by EMU geometry. Impress is refit to the window when the editor
    /// container settles and a fitting slide is centred in the viewport, so
    /// the object lands on the public gesture's anchor; the no-refit default
    /// zoom 10 projection also keeps the complete title visible. Identity is
    /// the owned note title; the OCR label is fixed and duplicated in the test.
    static let pinchCenterPresentationLaunchArgument = "--ui-test-office-pinch-center-presentation-fixture"
    static let pinchCenterPresentationDocumentName = "捏合验收-居中-演示-2.pptx"
    static let pinchCenterPresentationMeasuredText = "Pen UI 2Q8WZ4R6"

    static func seedCenteredPinchCalcDocumentIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              arguments.contains(pinchCenterCalcLaunchArgument) else { return }
        await seedOwnedOfficePinchDocument(name: pinchCenterCalcDocumentName) { url in
            // Sparse sheet kept identical to the builder probe fixture: a few
            // real cells for content, empty rows so the measured line stays
            // isolated for OCR, and the measured line in G10 (row 10, column G)
            // so the full 15-character title overflows into empty neighbours.
            var rows: [[String]] = [
                ["Region", "Q1", "Q2"],
                ["North", "120", "150"],
                ["South", "96", "210"],
            ]
            while rows.count < 9 { rows.append(["", "", "", "", "", "", ""]) }
            rows.append(["", "", "", "", "", "", pinchCenterCalcMeasuredText])
            try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [
                OfficeWorkbookSheet(name: "Pinch Anchor", rows: rows),
            ])
        }
    }

    static func seedCenteredPinchPresentationDocumentIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              arguments.contains(pinchCenterPresentationLaunchArgument) else { return }
        await seedOwnedOfficePinchDocument(name: pinchCenterPresentationDocumentName) { url in
            // The box is comfortable for the tested 24 pt metrics (283.5 pt
            // versus ~204 pt of text) and its geometry is the same one
            // asserted from the generated slide XML in the fixture evidence;
            // rendered wrapping and placement still await the actual UI run.
            try OfficeDocumentBuilder.createPresentation(at: url, title: "Pinch Center Deck", slides: [
                OfficePresentationSlide(title: "Pinch Center Deck", bullets: [
                    "Centered UIKit pinch acceptance fixture.",
                ], objects: [
                    OfficePresentationObject(kind: .text, name: "Measure",
                                             x: 4_296_000, y: 3_246_120,
                                             width: 3_600_000, height: 365_760,
                                             text: [pinchCenterPresentationMeasuredText],
                                             fontSize: 24),
                ]),
            ])
        }
    }

    /// Builds and imports one owned Office document through the same user-file
    /// import path as the Word fixture, idempotent by exact owned title
    /// (including Trash). Existing documents and every other library entry are
    /// left untouched; a failure is swallowed here and surfaces as the test's
    /// own honest visibility gate.
    private static func seedOwnedOfficePinchDocument(name: String,
                                                     _ build: (URL) throws -> Void) async {
        do {
            let store = try await NotesRepository.shared.store()
            let ownedTitle = (name as NSString).deletingPathExtension
            let existing = try await store.documents(includeTrash: true)
            guard !existing.contains(where: { $0.title == ownedTitle }) else { return }
            let scratch = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "notes")
            let root = scratch.url
            defer {
                try? FileManager.default.removeItem(at: root)
                scratch.lease.release()
            }
            let url = root.appendingPathComponent(name)
            try build(url)
            let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
            _ = try await store.create(draft)
        } catch {
            // A fixture failure leaves the pre-existing library untouched; the
            // acceptance test then fails honestly on its own visibility gate.
            // Record only the content-free NSError identity in the existing
            // Office stage trace, so a seeding failure is diagnosable without
            // logging a path, document text or the error description.
            let nsError = error as NSError
            OfficeStageRecorder.shared.record(
                session: "ui-test-pinch-fixture",
                generation: 0,
                stage: "pinchFixture.seedFailed",
                detail: ["domain": nsError.domain, "code": String(nsError.code)])
        }
    }
}
#endif
