import XCTest
import Foundation
@testable import FloeNotes
import FloeCore

/// Narrow G06 C5 localization regression for proposal summaries.
///
/// The Android shared overlay does not bundle the iOS `Localizable` catalog for
/// FloeNotes. `FloeL10n.l` therefore returns the key when no table is loaded,
/// which previously made the editor's proposal banner read
/// `notes.note_proposals.title`. `NoteLocalization.format` now supplies the
/// exact catalog EN/zh template with the real arguments, selected by the
/// current product language; the catalog still wins when it is present.
final class NotesLocalizationTests: XCTestCase {
    private let documentID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let pageID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let appendedPageID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let firstElement = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let removedElement = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let addedElement = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func before() -> NoteDocument {
        var document = NoteDocument(id: documentID, title: "Old title")
        document.tags = ["a"]
        document.isFavorite = false
        document.pages = [NotePage(id: pageID, elements: [
            NoteElement(id: firstElement, text: "keep"),
            NoteElement(id: removedElement, text: "remove"),
        ])]
        return document
    }

    private func after() -> NoteDocument {
        var document = before()
        document.title = "New title"
        document.tags = ["b"]
        document.isFavorite = true
        var page = document.pages[0]
        page.elements[0].text = "changed"
        page.elements.removeAll { $0.id == removedElement }
        page.elements.append(NoteElement(id: addedElement, text: "added"))
        document.pages[0] = page
        document.pages.append(NotePage(id: appendedPageID))
        return document
    }

    private func withLanguage(_ rawValue: String, _ body: () -> Void) {
        let defaults = UserDefaults(suiteName: "notes-proposal-l10n-\(UUID().uuidString)")!
        FloeL10n.setPreference(rawValue: rawValue, standardDefaults: defaults,
                               suiteDefaults: nil, arguments: [])
        defer {
            FloeL10n.setPreference(rawValue: nil, standardDefaults: defaults,
                                   suiteDefaults: nil, arguments: [])
        }
        body()
    }

    func testEnglishSummaryUsesRealTemplateAndArguments() {
        withLanguage("en") {
            XCTAssertEqual(FloeL10n.currentLanguageCode, "en")
            let summary = NoteProposalSummary.describe(before: before(), after: after())
            XCTAssertTrue(summary.contains("Title: “Old title” → “New title”"), summary)
            XCTAssertTrue(summary.contains("Add to favorites"), summary)
            XCTAssertTrue(summary.contains("Tags: a → b"), summary)
            XCTAssertTrue(summary.contains("Pages: 1 added, 0 deleted"), summary)
            XCTAssertTrue(summary.contains("Text/elements: 1 added, 1 changed, 1 deleted"), summary)
            XCTAssertFalse(summary.contains("notes."), "summary leaked an internal localization key: \(summary)")
            XCTAssertEqual(NoteProposalSummary.describe(before: before(), after: before()),
                           "No visible change")
        }
    }

    func testChineseSummaryUsesRealTemplateAndArguments() {
        withLanguage("zhHans") {
            XCTAssertEqual(FloeL10n.currentLanguageCode, "zh-Hans")
            let summary = NoteProposalSummary.describe(before: before(), after: after())
            XCTAssertTrue(summary.contains("标题：“Old title” → “New title”"), summary)
            XCTAssertTrue(summary.contains("加入收藏"), summary)
            XCTAssertTrue(summary.contains("标签：a → b"), summary)
            XCTAssertTrue(summary.contains("页面：新增 1，删除 0"), summary)
            XCTAssertTrue(summary.contains("文字/元素：新增 1，修改 1，删除 1"), summary)
            XCTAssertFalse(summary.contains("notes."), "summary leaked an internal localization key: \(summary)")
            XCTAssertEqual(NoteProposalSummary.describe(before: before(), after: before()),
                           "没有可见变化")
        }
    }

    func testStoreAndExportStringsUseTheMergedNotesFallback() async throws {
        let defaults = UserDefaults(suiteName: "notes-l10n-store-\(UUID().uuidString)")!
        defer {
            FloeL10n.setPreference(rawValue: nil, standardDefaults: defaults,
                                   suiteDefaults: nil, arguments: [])
        }

        FloeL10n.setPreference(rawValue: "en", standardDefaults: defaults,
                               suiteDefaults: nil, arguments: [])
        var enError = ""
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-notes-l10n-store-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NotesStore(root: root)
            _ = try await store.createNotebook(title: "")
            XCTFail("an empty notebook name must be refused")
        } catch NoteError.invalidOperation(let reason) {
            enError = reason
        }
        XCTAssertEqual(enError, "Enter a notebook name.")
        XCTAssertEqual(NoteLocalization.localized(
            "notes.note_export_selection.at_most_pages_can_be_exported", 5),
            "At most 5 pages can be exported at a time; export in batches.")

        FloeL10n.setPreference(rawValue: "zhHans", standardDefaults: defaults,
                               suiteDefaults: nil, arguments: [])
        var zhError = ""
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-notes-l10n-store-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NotesStore(root: root)
            _ = try await store.createNotebook(title: "")
            XCTFail("an empty notebook name must be refused")
        } catch NoteError.invalidOperation(let reason) {
            zhError = reason
        }
        XCTAssertEqual(zhError, "请输入笔记本名称。")
        XCTAssertEqual(NoteLocalization.localized(
            "notes.note_export_selection.at_most_pages_can_be_exported", 5),
            "一次最多导出 5 页，请分批导出。")
    }

    func testCoverAndTextFallbacksUseExistingTranslations() {
        withLanguage("en") {
            XCTAssertEqual(NoteLocalization.text(
                "notes.cover.error.invalidAsset",
                fallback: "This image can't be used as a cover"),
                "This image can't be used as a cover")
            XCTAssertEqual(NoteLocalization.text(
                "notes.note_models.invalid_cover_version",
                fallback: "The document cover version is invalid"),
                "The document cover version is invalid")
        }
        withLanguage("zhHans") {
            XCTAssertEqual(NoteLocalization.text(
                "notes.cover.error.invalidAsset",
                fallback: "This image can't be used as a cover"),
                "此图片无法用作封面")
            XCTAssertEqual(NoteLocalization.text(
                "notes.note_models.invalid_cover_version",
                fallback: "The document cover version is invalid"),
                "文档封面版本无效")
        }
    }

    func testUnknownNotesKeyNeverBecomesUserVisible() {
        withLanguage("en") {
            let text = NoteLocalization.localized("notes.unknown.key.for.test")
            XCTAssertFalse(text.contains("notes."), text)
            XCTAssertEqual(text, "The Notes action could not be completed.")
        }
        withLanguage("zhHans") {
            let text = NoteLocalization.localized("notes.unknown.key.for.test")
            XCTAssertFalse(text.contains("notes."), text)
            XCTAssertEqual(text, "手记操作未能完成。")
        }
    }

    func testProposalErrorAlsoAvoidsInternalKeysInBothLanguages() {
        withLanguage("en") {
            do {
                _ = try NoteProposalService.preview(document: before(), title: "Empty", edits: [])
                XCTFail("an empty proposal must be refused")
            } catch NoteError.invalidOperation(let reason) {
                XCTAssertEqual(reason, "The proposal contains no edits.")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        withLanguage("zhHans") {
            do {
                _ = try NoteProposalService.preview(document: before(), title: "Empty", edits: [])
                XCTFail("an empty proposal must be refused")
            } catch NoteError.invalidOperation(let reason) {
                XCTAssertEqual(reason, "提案不包含任何编辑。")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }
}
