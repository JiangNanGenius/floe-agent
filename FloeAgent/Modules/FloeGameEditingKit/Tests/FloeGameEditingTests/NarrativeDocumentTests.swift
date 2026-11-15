// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameEditingCore

@Suite("Narrative documents")
struct NarrativeDocumentTests {
    func makeDocument() -> NarrativeDocument {
        NarrativeDocument(title: "test",
            labels: [.init(name: "start"), .init(name: "end")],
            commands: [
                .init(code: "dialog", parameters: ["text": .string("Hi")]),
                .init(code: "branch", branchRole: .open, labelID: nil),
                .init(code: "dialog", parameters: ["text": .string("Inside")]),
                .init(code: "branchEnd", branchRole: .close),
                .init(code: "mystery", parameters: ["x": .number(1)], isSupported: false,
                      originalPayload: .object(["x": .number(1), "y": .string("z")]))
            ])
    }

    @Test("Insert, reorder and remove commands")
    @MainActor
    func editing() async throws {
        let document = makeDocument()
        let extra = NarrativeDocument.Command(code: "dialog", parameters: ["text": .string("New")])
        var edited = document.inserting(extra, at: 0)
        #expect(edited.commands.first?.id == extra.id)
        edited = edited.moving(id: extra.id, toIndex: 2)
        #expect(edited.commands[2].id == extra.id)
        edited = edited.removing(id: extra.id)
        #expect(edited == document)
    }

    @Test("Label editing keeps links consistent or reports them dangling")
    @MainActor
    func labels() async throws {
        let document = makeDocument()
        let startID = document.labels[0].id
        var edited = document.updating(id: document.commands[1].id) { $0.labelID = startID }
        // Branch/link structure is valid; the preserved unsupported command
        // still reports an informational issue.
        let branchIssues = edited.validationIssues().filter { $0.kind != .unsupportedCommandPresent }
        #expect(branchIssues.isEmpty)
        edited = edited.removingLabel(id: startID)
        #expect(edited.label(id: startID) == nil)
        // removingLabel nulls the link rather than inventing a target
        #expect(edited.commands[1].labelID == nil)
        edited = edited.updating(id: edited.commands[1].id) { $0.labelID = UUID() }
        let issues = edited.validationIssues()
        #expect(issues.contains { $0.kind == .danglingBranchLink })
    }

    @Test("Branch balance validation")
    @MainActor
    func branchBalance() async throws {
        let document = makeDocument()
        // Remove one close -> one open stays unbalanced; also verify close-first case.
        let closeID = document.commands[3].id
        var edited = document.removing(id: closeID)
        let issues = edited.validationIssues()
        #expect(issues.contains { $0.kind == .unbalancedOpen })
        let orphan = NarrativeDocument.Command(code: "branchEnd", branchRole: .close)
        edited = document.inserting(orphan, at: 0)
        #expect(edited.validationIssues().contains { $0.kind == .unbalancedClose })
    }

    @Test("Duplicate label names are reported")
    @MainActor
    func duplicateLabels() async throws {
        let document = makeDocument()
        let edited = document.addingLabel(name: "start")
        #expect(edited.validationIssues().contains { $0.kind == .duplicateLabelName })
    }

    @Test("Unsupported commands survive serialization with original payloads")
    @MainActor
    func unknownPreserved() async throws {
        let document = makeDocument()
        let bytes = try document.encode()
        let reopened = try NarrativeDocument.decode(bytes)
        #expect(reopened.commands.count == document.commands.count)
        let mystery = try #require(reopened.commands.first { $0.code == "mystery" })
        #expect(!mystery.isSupported)
        #expect(mystery.originalPayload == .object(["x": .number(1), "y": .string("z")]))
        #expect(reopened.validationIssues().contains { $0.kind == .unsupportedCommandPresent })
        // Re-encode after editing known commands keeps the payload stable.
        var edited = reopened
        edited = edited.updating(id: edited.commands[0].id) {
            $0.parameters["text"] = .string("Edited")
        }
        let reencoded = try edited.encode()
        let again = try NarrativeDocument.decode(reencoded)
        #expect(again.commands.first(where: { $0.code == "mystery" })?.originalPayload == mystery.originalPayload)
    }
}
