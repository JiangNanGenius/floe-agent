import Foundation
import Testing
@testable import FloeSecurity
@testable import FloeModels

@Suite("FloeSecurity.ApprovalDecisionParser")
struct ApprovalDecisionParserTests {
    private let parser = ApprovalDecisionParser()

    @Test("Accepts weak model formatting", arguments: [
        (#"{"decision":"allow","reason":"read only"}"#, ApprovalDecisionParser.Outcome.allow),
        ("```json\n{\"result\":\"批准\"}\n```", .allow),
        ("Decision: DENY", .deny),
        ("结论： ASK", .ask),
        (#"{"approved":true}"#, .allow),
        ("允许", .allow),
        ("批准，因为这是只读操作。", .allow),
        ("ALLOW because there is no reason to deny this read.", .allow),
        ("审核结果：无需阻止，风险边界明确。", .allow),
        ("不能批准：需要用户确认。", .deny),
        ("I approve this bounded operation.", .allow),
        ("Requires human confirmation.", .ask)
    ])
    func acceptsFormatting(caseItem: (String, ApprovalDecisionParser.Outcome)) throws {
        #expect(try parser.parse(caseItem.0).outcome == caseItem.1)
    }

    @Test("Contradictory decisions are rejected")
    func rejectsContradiction() {
        #expect(throws: ApprovalDecisionParser.ParseError.self) {
            try parser.parse("ALLOW\nDENY")
        }
    }
}
