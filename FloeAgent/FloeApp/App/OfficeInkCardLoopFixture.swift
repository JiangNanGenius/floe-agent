// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import FloeCore
import FloeDocuments
import FloeNotes
import FloePersistence

/// DEBUG-only owned-document seeding for the actual Main-App saved-ink
/// library-card UI loop acceptance (Word/Calc/Deck).
///
/// It mirrors `OfficeWorkspaceStageFixture`'s established pinch-fixture
/// convention: one explicit launch argument per format plus one per-run token
/// argument, a real `OfficeDocumentBuilder` package (no synthetic zip), and
/// the same `NoteFileImporter.importFile` path a user file import uses. The
/// document is therefore a genuine imported Notes document with an ordinary
/// resource, revision and card.
///
/// The token makes every acceptance run target a UNIQUE task-owned document:
/// the pre-save card cannot carry ink from an earlier run, so the
/// "baseline no red / final red" gates are honest. Nothing else in the
/// library is read, changed or deleted. A seeding failure is recorded as a
/// content-free NSError identity in the existing Office stage trace and the
/// UI test then fails honestly on its own visibility gate.
///
/// The content is a SYNTHETIC fixture: the marker text is deterministic and
/// stays inside the document so the committed-resource postflight can verify
/// original-content retention. No path, no user content, and no raw token is
/// ever logged by this file beyond the fixture-owned identity itself.
@MainActor
enum OfficeInkCardLoopFixture {
    static let wordLaunchArgument = "--ui-test-office-ink-card-word-fixture"
    static let calcLaunchArgument = "--ui-test-office-ink-card-calc-fixture"
    static let presentationLaunchArgument = "--ui-test-office-ink-card-presentation-fixture"
    /// Value argument: the NEXT element is the run token. Parsed locally and
    /// validated strictly; an absent or malformed token disarms the fixture.
    static let tokenLaunchArgument = "--ui-test-office-ink-card-token"

    /// Fixture-owned library title prefix. Titles carry no "." or "#" so the
    /// card identity `notes.card.office.<title>.<source>#<revision>` remains
    /// parseable by the exact production identifier convention.
    static let titlePrefix = "墨卡闭环"

    enum Format: String {
        case word
        case calc
        case presentation

        var fileSuffix: String {
            switch self {
            case .word: return "Word"
            case .calc: return "Calc"
            case .presentation: return "Deck"
            }
        }
        var fileExtension: String {
            switch self {
            case .word: return "docx"
            case .calc: return "xlsx"
            case .presentation: return "pptx"
            }
        }
    }

    static var requestedFormat: Format? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(wordLaunchArgument) { return .word }
        if arguments.contains(calcLaunchArgument) { return .calc }
        if arguments.contains(presentationLaunchArgument) { return .presentation }
        return nil
    }

    /// 4...12 lowercase alphanumeric token following the value argument.
    /// Strict so a malformed run cannot silently seed an unparseable title.
    static var requestedToken: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: tokenLaunchArgument),
              index + 1 < arguments.count else { return nil }
        let raw = arguments[index + 1]
        func allowed(_ character: Character) -> Bool {
            guard character.isASCII else { return false }
            if character.isNumber { return true }
            return character.isLetter && character.isLowercase
        }
        guard raw.count >= 4, raw.count <= 12, raw.allSatisfy(allowed) else { return nil }
        return raw
    }

    static var isArmed: Bool { requestedFormat != nil && requestedToken != nil }

    static func ownedTitle(format: Format, token: String) -> String {
        "\(titlePrefix)-\(format.fileSuffix)-\(token)"
    }

    /// The working-copy name the Notes staging keeps verbatim
    /// (`stageWorkingCopy` requires `fileName == lastPathComponent`), so the
    /// engine's own document name is exactly this string — the seam uses it
    /// as the ownership identity for the current editor.
    static func ownedFileName(format: Format, token: String) -> String {
        "inkcard-\(format.rawValue)-\(token).\(format.fileExtension)"
    }

    /// Synthetic original-content marker. Deterministic per run, present in
    /// every format's primary content part, and retained by the engine save.
    static func markerText(format: Format, token: String) -> String {
        "INKCARD-ORIG-\(format.fileSuffix)-\(token)"
    }

    static func seedIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let format = requestedFormat,
              let token = requestedToken else { return }
        let ownedTitle = ownedTitle(format: format, token: token)
        let fileName = ownedFileName(format: format, token: token)
        do {
            let store = try await NotesRepository.shared.store()
            let existing = try await store.documents(includeTrash: true)
            guard !existing.contains(where: { $0.title == ownedTitle }) else { return }
            let scratch = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "notes")
            let root = scratch.url
            defer {
                try? FileManager.default.removeItem(at: root)
                scratch.lease.release()
            }
            let url = root.appendingPathComponent(fileName)
            let marker = markerText(format: format, token: token)
            switch format {
            case .word:
                // The marker is a real body paragraph near the top so the
                // first-page saved cover shows original content; no drawing
                // object of any kind is pre-seeded (the baseline card must
                // be ink-free because the document contains no ink).
                try OfficeDocumentBuilder.createWord(at: url, title: "Ink Card Loop", paragraphs: [
                    marker,
                    "Office 保存墨迹闭环验收（合成夹具，Word）。",
                    "Main-App saved-ink loop fixture body row one.",
                    "Main-App saved-ink loop fixture body row two.",
                ])
            case .calc:
                var rows: [[String]] = [
                    ["Task", "Q1", "Q2"],
                    ["Ink Loop", "120", "150"],
                    ["North", "96", "210"],
                ]
                rows.append([marker, "", ""])
                while rows.count < 10 { rows.append(["", "", ""]) }
                rows.append(["Footer", "7", "9"])
                try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [
                    OfficeWorkbookSheet(name: "Ink Loop", rows: rows),
                ])
            case .presentation:
                // The text object is centred by the same EMU geometry the
                // accepted pinch deck uses, so the marker stays inside the
                // first-slide frame the saved cover renders.
                try OfficeDocumentBuilder.createPresentation(at: url, title: "Ink Card Deck", slides: [
                    OfficePresentationSlide(title: "Ink Card Deck", bullets: [
                        "Main-App saved-ink loop fixture slide.",
                    ], objects: [
                        OfficePresentationObject(kind: .text, name: "InkCard",
                                                 x: 4_296_000, y: 3_246_120,
                                                 width: 3_600_000, height: 365_760,
                                                 text: [marker],
                                                 fontSize: 24),
                    ]),
                ])
            }
            var draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
            draft.title = ownedTitle
            _ = try await store.create(draft)
        } catch {
            // A fixture failure leaves the pre-existing library untouched;
            // the acceptance test fails honestly on its own visibility gate.
            // Record only the content-free NSError identity in the existing
            // Office stage trace, so a seeding failure is diagnosable without
            // logging a path, document text or the error description.
            let nsError = error as NSError
            OfficeStageRecorder.shared.record(
                session: "ui-test-ink-card-fixture",
                generation: 0,
                stage: "inkCardFixture.seedFailed",
                detail: ["domain": nsError.domain, "code": String(nsError.code)])
        }
    }
}
#endif
