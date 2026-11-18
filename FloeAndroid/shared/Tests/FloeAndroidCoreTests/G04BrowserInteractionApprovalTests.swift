// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeTools
import FloeAgentRuntime
import FloeBrowser
@testable import FloeAndroidCore

final class G04BrowserInteractionApprovalTests: XCTestCase {
    func testClosedGrammarRejectsUnreviewedFieldsAndRetainsSubmit() throws {
        func waiting(_ name: String, _ json: String) throws -> AgentState.WaitingApproval {
            AgentState.WaitingApproval(toolCall: try ToolCall(id: "c1", toolName: name,
                argumentsJSON: Data(json.utf8), scope: .local), reason: "test")
        }
        let allowed = try waiting("browser.type", #"{"ref":"n1","documentID":"d1","text":"example","submit":true}"#)
        guard case .type(.element(let ref, let document), let text, let submit)? =
            G04BrowserInteractionApprovalPresentation.arguments(allowed)?.0 else { return XCTFail("type was not parsed") }
        XCTAssertEqual(ref, "n1"); XCTAssertEqual(document, "d1"); XCTAssertEqual(text, "example"); XCTAssertTrue(submit)
        XCTAssertNil(G04BrowserInteractionApprovalPresentation.arguments(try waiting("browser.click", #"{"ref":"n1","documentID":"d1","extra":true}"#)))
        XCTAssertNil(G04BrowserInteractionApprovalPresentation.arguments(try waiting("browser.scroll", #"{"deltaY":20001}"#)))
    }

    func testPrivateProofIsOneUseAndNeverProjectsInputDigest() throws {
        let run = UUID(), grant = UUID(), task = UUID()
        let owner = BrowserOwnerID(taskID: task, workspaceID: UUID(), rootEpoch: 7)
        let proof = BrowserInteractionApprovalProof(owner: owner, sessionID: UUID(), operation: "type",
            requestedTabID: nil, tabID: UUID(), documentID: "doc", navigationRevision: 3,
            documentToken: "token", pageRevision: 4, url: "https://example.test/", title: "Example",
            ref: "n1", role: "input", label: "Search", textDigest: "private-digest", textBytes: 7,
            submit: false, deltaX: nil, deltaY: nil)
        let details = try XCTUnwrap(G04BrowserInteractionApprovalPresentation.details(proof))
        XCTAssertNil(details["textDigest"])
        XCTAssertEqual(details["textBytes"], .integer(7))
        let gate = G04BrowserInteractionApprovalGate.shared
        XCTAssertTrue(gate.stage(run: run, call: "c1", grant: grant, proof: proof))
        XCTAssertNil(gate.take(run: run, call: "other", grant: grant))
        XCTAssertEqual(gate.take(run: run, call: "c1", grant: grant), proof)
        XCTAssertNil(gate.take(run: run, call: "c1", grant: grant))
    }
    func testClickPointRejectsUnknownArgumentsAndBindsVisibleEvidence() throws {
        let sha = String(repeating: "a", count: 64)
        func waiting(_ json: String) throws -> AgentState.WaitingApproval {
            AgentState.WaitingApproval(toolCall: try ToolCall(id: "c", toolName: "browser.clickPoint",
                argumentsJSON: Data(json.utf8), scope: .local), reason: "test")
        }
        let json = "{\"documentID\":\"doc\",\"x\":12,\"y\":13,\"screenshotSHA256\":\"\(sha)\",\"fallbackReason\":\"noStructuredTarget\"}"
        let parsed = try XCTUnwrap(G04BrowserInteractionApprovalPresentation.arguments(try waiting(json)))
        XCTAssertEqual(parsed.2, sha); XCTAssertEqual(parsed.3, "noStructuredTarget"); XCTAssertEqual(parsed.4, "doc")
        XCTAssertNil(G04BrowserInteractionApprovalPresentation.arguments(try waiting(String(json.dropLast()) + ",\"extra\":true}")))
        let artifactID = UUID()
        let artifact = BrowserArtifactReference(id: artifactID, relativePath: "BrowserArtifacts/\(artifactID.uuidString).jpg",
            mimeType: "image/jpeg", byteCount: 123, sha256: sha, pixelWidth: 100, pixelHeight: 200)
        let visual = BrowserVisualApprovalEvidence(artifact: artifact, x: 12, y: 13,
            fallbackReason: "noStructuredTarget", viewportWidth: 100, viewportHeight: 200, scrollX: 0, scrollY: 0)
        let proof = BrowserInteractionApprovalProof(owner: BrowserOwnerID(taskID: UUID(), workspaceID: UUID(), rootEpoch: 7),
            sessionID: UUID(), operation: "clickPoint", requestedTabID: nil, tabID: UUID(), documentID: "doc",
            navigationRevision: 3, documentToken: "private", pageRevision: 4, url: "https://example.test/",
            title: nil, ref: nil, role: nil, label: nil, textDigest: nil, textBytes: nil,
            submit: nil, deltaX: nil, deltaY: nil, visual: visual)
        let details = try XCTUnwrap(G04BrowserInteractionApprovalPresentation.details(proof))
        XCTAssertEqual(details["evidenceSHA256"], .string(sha))
        XCTAssertEqual(details["pointX"], .fractional(12))
        XCTAssertNil(details["documentToken"])
        XCTAssertNil(details["viewportWidth"])
    }

}
