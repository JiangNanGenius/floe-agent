// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeNotes
import FloeSecurity
import FloeTools
@testable import FloeNotesNativeQualification

/// Approval-boundary checks for the document assistant grant: scoped
/// handlers inherit the task grant, exec requires the guest-confined session
/// environment and the task network policy, and everything outside the
/// reduced catalog keeps the human card.
final class NotesDocumentApprovalPolicyTests: XCTestCase {

    private func makeStore() throws -> (NotesStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try NotesStore(root: root), root)
    }

    private func action(_ toolName: String, argumentsJSON: String = "{}", scope: ToolScope = .local) -> ProposedAction {
        ProposedAction(
            toolCall: try! ToolCall(
                id: "call-1",
                toolName: toolName,
                argumentsJSON: Data(argumentsJSON.utf8),
                scope: scope
            ),
            riskLabels: [],
            userGoal: "整理这份文档",
            hostAndPathScope: scope
        )
    }

    private func assertEscalates(_ decision: ApprovalDecision, _ message: String) {
        guard case .escalateToHuman = decision else {
            return XCTFail("expected escalation, got \(decision): \(message)")
        }
    }

    private func assertAllowed(_ decision: ApprovalDecision, _ message: String) {
        guard case .allow = decision else {
            return XCTFail("expected allow, got \(decision): \(message)")
        }
    }

    func testDocumentEditGrantRequiresOwnership() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let owned = try await store.create(NoteDocument(kind: .notebook, title: "已授权"))
        let stranger = try await store.create(NoteDocument(kind: .notebook, title: "未授权"))
        try await store.bindAssistant(conversationID: conversationID, documentID: owned.id, canEdit: true)
        let policy = NotesDocumentApprovalPolicy(conversationID: conversationID, store: store)

        assertAllowed(try await policy.decide(action(NotesEditTool.name, argumentsJSON: #"{"documentID":"\#(owned.id.uuidString)","expectedRevision":1,"edits":[]}"#)), "owned document edit inherits the grant")
        let denied = try await policy.decide(action(NotesEditTool.name, argumentsJSON: #"{"documentID":"\#(stranger.id.uuidString)","expectedRevision":1,"edits":[]}"#))
        guard case .deny = denied else {
            return XCTFail("expected deny for a document outside the assistant session, got \(denied)")
        }
    }

    func testScopedHandlersInheritTheTaskGrant() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = NotesDocumentApprovalPolicy(
            conversationID: UUID(), store: store,
            executionConfined: true, networkPermitted: true
        )
        for name in [
            "notes.read", "notes.search", "notes.attachFile", "notes.stageAttachment",
            "workspace.readFile", "workspace.writeFile", "workspace.listDirectory",
            "document.pdf.inspect", "document.office.inspect", "image.ocr",
            "conversation.search", "conversation.read", "conversation.list",
            "checklist.readPlan", "checklist.updatePlan", "memory.recall",
            "tools.search", "tools.list"
        ] {
            assertAllowed(try await policy.decide(action(name)), "\(name) is a scoped handler")
        }
    }

    func testExecRequiresConfinedSessionAndNetworkPolicy() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()

        let confined = NotesDocumentApprovalPolicy(
            conversationID: conversationID, store: store,
            executionConfined: true, networkPermitted: true
        )
        assertAllowed(
            try await confined.decide(action("exec.localPython", argumentsJSON: #"{"script":"print(1)"}"#)),
            "confined guest script inherits the grant"
        )
        assertAllowed(
            try await confined.decide(action("exec.localPython", argumentsJSON: #"{"script":"import pandas","packages":["pandas"],"packagePurpose":"chart"}"#)),
            "installing a compatible dependency into the task environment inherits scope when downloads are permitted"
        )
        assertAllowed(
            try await confined.decide(action("exec.shell", argumentsJSON: #"{"command":"pip install pillow"}"#)),
            "shell pip install into the task environment inherits scope when downloads are permitted"
        )

        let unconfined = NotesDocumentApprovalPolicy(
            conversationID: conversationID, store: store,
            executionConfined: false, networkPermitted: true
        )
        assertEscalates(
            try await unconfined.decide(action("exec.localPython", argumentsJSON: #"{"script":"print(1)"}"#)),
            "no guest-confined session environment: fail closed to the human card"
        )
        assertEscalates(
            try await unconfined.decide(action("exec.shell", argumentsJSON: #"{"command":"ls"}"#)),
            "shell is never auto-granted outside the confined session"
        )

        let offline = NotesDocumentApprovalPolicy(
            conversationID: conversationID, store: store,
            executionConfined: true, networkPermitted: false
        )
        assertEscalates(
            try await offline.decide(action("exec.localPython", argumentsJSON: #"{"script":"print(1)"}"#)),
            "the task network policy, not the script text, is the network lever"
        )
    }

    func testOutOfScopeActionsKeepTheHumanCard() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = NotesDocumentApprovalPolicy(
            conversationID: UUID(), store: store,
            executionConfined: true, networkPermitted: true
        )
        assertEscalates(
            try await policy.decide(action("image.inspect", argumentsJSON: #"{"path":"inputs/a.png"}"#)),
            "provider-backed semantic sends of document bytes ask first"
        )
        assertEscalates(
            try await policy.decide(action("mail.send", argumentsJSON: #"{"to":"a@b.c"}"#)),
            "external share/send actions are separately permissioned"
        )
        assertEscalates(
            try await policy.decide(action("ssh.execute", argumentsJSON: #"{"command":"uptime"}"#)),
            "remote actions are outside the document grant"
        )
        assertEscalates(
            try await policy.decide(action("notes.read", scope: .host(UUID()))),
            "non-local scope never inherits the local document grant"
        )
    }
}
