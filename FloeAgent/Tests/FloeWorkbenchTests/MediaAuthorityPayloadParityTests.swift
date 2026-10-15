// FloeWorkbenchTests — runtime ↔ tool payload-digest parity for media apply.
//
// The runtime mints the automatic-apply authority from the RAW approved
// argument bytes (`RuntimeAuthorityDigest.payloadDigest(call.argumentsJSON)`),
// and the tool consumes it with the digest of its canonical approved payload.
// The two must agree for the ordinary flow: the model echoes the exact id
// strings the tool printed (`capabilities`/`propose` print `uuidString`), and
// the canonical payload must therefore keep the RAW approved spelling instead
// of re-spelling identifiers. A re-spelled id remains a DIFFERENT payload
// (exact-spelling binding, mirrors the CAD applied-proposal contract).

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeWorkbench

@Suite("FloeWorkbench.media automatic-apply payload parity")
struct MediaAuthorityPayloadParityTests {

    private func rawApply(projectID: String, proposalID: String) -> Data {
        Data(#"{"action":"apply","project_id":"\#(projectID)","proposal_id":"\#(proposalID)"}"#.utf8)
    }

    @Test("the canonical approved payload digests identically to the raw approved call")
    func rawSpellingParity() throws {
        let project = UUID()
        let proposal = UUID()
        // Exactly what a model echoes from the tool output (uppercase
        // `uuidString`), and the same call in lowercase: both bind their own
        // raw bytes because the canonical payload preserves the spelling.
        for (projectRaw, proposalRaw) in [
            (project.uuidString, proposal.uuidString),
            (project.uuidString.lowercased(), proposal.uuidString.lowercased())
        ] {
            let raw = rawApply(projectID: projectRaw, proposalID: proposalRaw)
            let args = try JSONDecoder().decode(MediaProjectArguments.self, from: raw)
            let canonical = try MediaProjectTool.canonicalApprovedPayload(args)
            #expect(RuntimeAuthorityDigest.payloadDigest(canonical)
                    == RuntimeAuthorityDigest.payloadDigest(raw),
                    "consumer digest must match the runtime digest for \(projectRaw)")
        }
    }

    @Test("a re-spelled proposal id is a different payload")
    func reSpelledIDIsDifferent() throws {
        let project = UUID()
        let proposal = UUID()
        let upper = try JSONDecoder().decode(
            MediaProjectArguments.self,
            from: rawApply(projectID: project.uuidString, proposalID: proposal.uuidString))
        let lower = try JSONDecoder().decode(
            MediaProjectArguments.self,
            from: rawApply(projectID: project.uuidString, proposalID: proposal.uuidString.lowercased()))
        #expect(RuntimeAuthorityDigest.payloadDigest(try MediaProjectTool.canonicalApprovedPayload(upper))
                != RuntimeAuthorityDigest.payloadDigest(try MediaProjectTool.canonicalApprovedPayload(lower)))
    }

    @Test("decoded ids still parse; an invalid id is refused")
    func decodingContract() throws {
        let project = UUID()
        let args = try JSONDecoder().decode(
            MediaProjectArguments.self,
            from: rawApply(projectID: project.uuidString, proposalID: UUID().uuidString))
        #expect(args.projectID == project)
        #expect(args.projectIDRaw == project.uuidString)
        #expect(args.proposalID != nil)
        #expect(args.proposalIDRaw != nil)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(MediaProjectArguments.self,
                                     from: Data(#"{"action":"read","project_id":"not-a-uuid"}"#.utf8))
        }
    }
}
