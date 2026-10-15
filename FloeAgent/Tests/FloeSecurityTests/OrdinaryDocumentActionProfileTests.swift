// FloeSecurityTests — the compiled ordinary read/draft action profile.
//
// The profile is the audited answer to "does this exact mixed-tool action
// write original bytes?" consumed by the deterministic approval carve-out.
// These tests pin the table itself: every listed family/action, the
// draft/read role split, the fail-closed nil for unlisted or unknown values,
// and the fact that model-authored "readOnly"/"safe" flags change nothing.

import Foundation
import Testing
@testable import FloeSecurity

@Suite("FloeSecurity.OrdinaryDocumentActionProfile")
struct OrdinaryDocumentActionProfileTests {

    private func role(_ tool: String, _ json: String) -> OrdinaryDocumentActionRole? {
        OrdinaryDocumentActionProfile.role(forToolName: tool, argumentsJSON: Data(json.utf8))
    }

    @Test("Office read/draft actions are classified; write actions stay unlisted")
    func officeActions() {
        #expect(role("document.office.edit", #"{"action":"capabilities"}"#) == .readOnly)
        #expect(role("document.office.edit", #"{"action":"query","path":"a.docx"}"#) == .readOnly)
        #expect(role("document.office.edit", #"{"action":"read","path":"a.docx"}"#) == .readOnly)
        #expect(role("document.office.edit", #"{"action":"errors","path":"a.xlsx"}"#) == .readOnly)
        #expect(role("document.office.edit", #"{"action":"preview","proposal_id":"p"}"#) == .readOnly)
        #expect(role("document.office.edit",
                     #"{"action":"propose","path":"a.docx","expected_sha256":"x"}"#) == .draftOnly)
        // Write actions keep the write-target contract (and the existing
        // review for repository targets).
        #expect(role("document.office.edit", #"{"action":"apply","path":"a.docx","proposal_id":"p"}"#) == nil)
        #expect(role("document.office.edit", #"{"action":"export","path":"a.docx"}"#) == nil)
        #expect(role("document.office.edit", #"{"action":"replaceImage","path":"a.docx"}"#) == nil)
        // Case/whitespace normalization matches the write contract.
        #expect(role("document.office.edit", #"{"action":" Read "}"#) == .readOnly)
    }

    @Test("media.project reads/drafts are classified; apply/export stay unlisted")
    func mediaProjectActions() {
        let id = UUID().uuidString
        #expect(role("media.project", #"{"action":"capabilities","project_id":"\#(id)"}"#) == .readOnly)
        #expect(role("media.project", #"{"action":"read","project_id":"\#(id)"}"#) == .readOnly)
        #expect(role("media.project", #"{"action":"propose","project_id":"\#(id)"}"#) == .draftOnly)
        #expect(role("media.project", #"{"action":"apply","project_id":"\#(id)","proposal_id":"p"}"#) == nil)
        #expect(role("media.project", #"{"action":"export","project_id":"\#(id)"}"#) == nil)
    }

    @Test("CAD read/draft actions are classified; cancel/assembly and writes stay unlisted")
    func cadDocumentActions() {
        for action in ["capabilities", "read", "query", "locate", "measure", "check",
                       "status", "three_d_snapshot", "three_d_measure", "preview"] {
            #expect(role("cad.document", #"{"action":"\#(action)","path":"part.dwg"}"#) == .readOnly,
                    "cad \(action) is read-only")
        }
        #expect(role("cad.document", #"{"action":"propose","path":"part.dwg"}"#) == .draftOnly)
        #expect(role("cad.document", #"{"action":"three_d_propose","path":"part.floecad"}"#) == .draftOnly)
        // Task-state mutation, payload-dependent mutation and every write
        // action keep the existing policy.
        for action in ["cancel", "assembly", "drawing", "three_d_assembly", "three_d_drawing",
                       "create", "apply", "save", "import", "three_d_apply", "export"] {
            #expect(role("cad.document", #"{"action":"\#(action)","path":"part.floecad"}"#) == nil,
                    "cad \(action) must not be classified as an ordinary read/draft")
        }
    }

    @Test("SVG inspect is a read; edit and unknown tools/actions fail closed")
    func svgAndUnknown() {
        #expect(role("image.svgDocument", #"{"operation":"inspect","path":"a.svg"}"#) == .readOnly)
        #expect(role("image.svgDocument", #"{"operation":"edit","path":"a.svg","outputPath":"b.svg"}"#) == nil)
        #expect(role("workspace.writeFile", #"{"path":"a.txt","content":"x"}"#) == nil)
        #expect(role("document.pdf.edit", #"{"inputPath":"a.pdf","outputPath":"b.pdf"}"#) == nil)
        #expect(role("document.office.edit", #"{"action":"readDocument"}"#) == nil)
        #expect(role("document.office.edit", #"{"action":"DELETE"}"#) == nil)
        #expect(role("document.office.edit", #"{}"#) == nil)
        #expect(role("document.office.edit", #"not json"#) == nil)
    }

    @Test("A model-authored safe/readOnly flag never creates a role")
    func modelFlagsAreIgnored() {
        // The flag is not consulted: a WRITE action stays unlisted even with
        // every safe-looking flag, and a listed read action is classified by
        // its action value alone (the flag changes nothing).
        #expect(role("document.office.edit",
                     #"{"action":"apply","path":"a.docx","readOnly":true,"safe":true,"confirmed":true}"#) == nil)
        #expect(role("cad.document",
                     #"{"action":"save","path":"part.floecad","safeRead":true}"#) == nil)
        #expect(role("document.office.edit",
                     #"{"action":"read","path":"a.docx","readOnly":false}"#) == .readOnly)
    }
}
