// FloeDocumentsTests — runtime ↔ tool payload-digest parity for office apply.
//
// The runtime mints the automatic-apply authority from the RAW approved
// argument bytes (`RuntimeAuthorityDigest.payloadDigest(call.argumentsJSON)`),
// and the tool consumes it with the digest of its canonical approved payload.
// These must agree for the ordinary flow: `propose` prints the proposal id as
// `uuidString` and the model echoes it, so the canonical payload keeps the RAW
// approved spelling (a re-spelled id stays a DIFFERENT payload — exact-spelling
// binding, mirrors the CAD applied-proposal contract).

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeDocuments

@Suite("FloeDocuments.office automatic-apply payload parity")
struct OfficeAuthorityPayloadParityTests {

    private func rawApply(proposalID: String) -> Data {
        Data(#"{"action":"apply","path":"book.xlsx","proposal_id":"\#(proposalID)"}"#.utf8)
    }

    @Test("the canonical approved payload digests identically to the raw approved call")
    func rawSpellingParity() throws {
        let proposal = UUID()
        for proposalRaw in [proposal.uuidString, proposal.uuidString.lowercased()] {
            let raw = rawApply(proposalID: proposalRaw)
            let args = try JSONDecoder().decode(OfficeEditArguments.self, from: raw)
            let canonical = try OfficeEditTool.canonicalApprovedPayload(args)
            #expect(RuntimeAuthorityDigest.payloadDigest(canonical)
                    == RuntimeAuthorityDigest.payloadDigest(raw),
                    "consumer digest must match the runtime digest for \(proposalRaw)")
        }
    }

    @Test("a re-spelled proposal id is a different payload")
    func reSpelledIDIsDifferent() throws {
        let proposal = UUID()
        let upper = try JSONDecoder().decode(
            OfficeEditArguments.self, from: rawApply(proposalID: proposal.uuidString))
        let lower = try JSONDecoder().decode(
            OfficeEditArguments.self, from: rawApply(proposalID: proposal.uuidString.lowercased()))
        #expect(RuntimeAuthorityDigest.payloadDigest(try OfficeEditTool.canonicalApprovedPayload(upper))
                != RuntimeAuthorityDigest.payloadDigest(try OfficeEditTool.canonicalApprovedPayload(lower)))
    }

    @Test("decoded ids still parse; an invalid id is refused")
    func decodingContract() throws {
        let proposal = UUID()
        let args = try JSONDecoder().decode(OfficeEditArguments.self, from: rawApply(proposalID: proposal.uuidString))
        #expect(args.proposalID == proposal)
        #expect(args.proposalIDRaw == proposal.uuidString)
        // The programmatic memberwise construction stays supported.
        let built = OfficeEditArguments(action: .apply, path: "book.xlsx", proposalID: proposal)
        #expect(built.proposalIDRaw == nil)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(OfficeEditArguments.self,
                                     from: Data(#"{"action":"apply","proposal_id":"nope"}"#.utf8))
        }
    }

    @Test("a decoded-then-mutated proposal id never reuses the stale raw spelling")
    func mutatedIDNeverReusesStaleRaw() throws {
        let original = UUID()
        let replacement = UUID()
        var args = try JSONDecoder().decode(
            OfficeEditArguments.self, from: rawApply(proposalID: original.uuidString))
        #expect(args.proposalIDRaw == original.uuidString)

        // Mutating the decoded id must not keep binding the OLD spelling: the
        // canonical payload follows the CURRENT id.
        args.proposalID = replacement
        let canonical = try OfficeEditTool.canonicalApprovedPayload(args)
        let object = try #require(
            try JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        #expect(object["proposal_id"] as? String == replacement.uuidString)

        // Dropping the id removes it from the payload entirely.
        args.proposalID = nil
        let cleared = try JSONSerialization.jsonObject(
            with: try OfficeEditTool.canonicalApprovedPayload(args)) as? [String: Any]
        #expect(cleared?["proposal_id"] == nil)

        // The raw spelling is reused only while it still parses to the
        // CURRENT id; case (upper/lowercase) is preserved when it does.
        #expect(OfficeEditTool.approvedProposalIDSpelling(replacement, raw: replacement.uuidString)
                == replacement.uuidString)
        #expect(OfficeEditTool.approvedProposalIDSpelling(replacement, raw: replacement.uuidString.lowercased())
                == replacement.uuidString.lowercased())
        #expect(OfficeEditTool.approvedProposalIDSpelling(replacement, raw: original.uuidString)
                == replacement.uuidString)
        #expect(OfficeEditTool.approvedProposalIDSpelling(replacement, raw: "not-a-uuid")
                == replacement.uuidString)
    }
}
