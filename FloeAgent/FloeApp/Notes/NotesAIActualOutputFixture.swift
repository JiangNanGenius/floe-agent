// FloeApp — DEBUG-only fixture: open the ACTUAL AI-produced Office outputs in
// the normal Notes UI (G2 task-lifecycle round).
//
// SPDX-License-Identifier: MPL-2.0
#if DEBUG
import Crypto
import Foundation
import FloeNotes

/// Imports the genuine outputs of the R live-AI qualification run (the Word
/// acceptance-table.docx copy, the recalculated Excel copy and the duplicated
/// deck) into synthetic Notes documents through the REAL `NoteFileImporter`
/// path, so the normal App can show the actual bytes with its standard Notes
/// card / Office preview. The bytes are passed by the UI test through the
/// launch environment (base64) together with their SHA-256, so a drifted
/// fixture is rejected instead of silently seeding a different document.
///
/// Nothing is regenerated here and no fixture is swapped: these are the exact
/// bytes the live run produced (and that the primary independently validated).
/// Gated on `-ui-testing` plus an explicit launch argument and simulator-only;
/// idempotent by note title.
@MainActor
enum NotesAIActualOutputFixture {
    static let launchArgument = "--ui-test-notes-ai-output-fixture"

    struct Item {
        let base64Key: String
        let shaKey: String
        let fileName: String
    }

    /// File names become the imported note titles (the importer titles a note
    /// from the file basename).
    static let items: [Item] = [
        Item(base64Key: "FLOE_AI_OUTPUT_WORD_B64",
             shaKey: "FLOE_AI_OUTPUT_WORD_SHA256",
             fileName: "AI 输出-表格.docx"),
        Item(base64Key: "FLOE_AI_OUTPUT_XLSX_B64",
             shaKey: "FLOE_AI_OUTPUT_XLSX_SHA256",
             fileName: "AI 输出-表格数据.xlsx"),
        Item(base64Key: "FLOE_AI_OUTPUT_PPTX_B64",
             shaKey: "FLOE_AI_OUTPUT_PPTX_SHA256",
             fileName: "AI 输出-演示.pptx")
    ]

    static func seedIfRequested(session: NotesSession) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        #if targetEnvironment(simulator)
        guard let store = session.store else { return }
        let environment = ProcessInfo.processInfo.environment
        let existing = (try? await store.documents(includeTrash: true)) ?? []
        var existingTitles = Set(existing.map(\.title))
        var imported = false
        for item in items {
            guard let encoded = environment[item.base64Key],
                  let data = Data(base64Encoded: encoded), !data.isEmpty,
                  let expected = environment[item.shaKey] else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else {
                // A drifted fixture must never be presented as the actual run
                // output; the UI test fails when the card is missing.
                continue
            }
            let title = (item.fileName as NSString).deletingPathExtension
            guard !existingTitles.contains(title) else { continue }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("notes-ai-output-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent(item.fileName)
            do {
                try data.write(to: url, options: .atomic)
                let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
                _ = try? await store.create(draft)
                existingTitles.insert(title)
                imported = true
            } catch {
                // The missing card is the visible failure the test asserts on.
            }
        }
        if imported { try? await session.reload() }
        #endif
    }
}
#endif
