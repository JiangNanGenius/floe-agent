// SPDX-License-Identifier: MPL-2.0
//
// Project registration and durable attachment tests for the Mac
// self-owned runtime. Every root is a fresh 0700 temporary directory; no
// user database, Keychain item or workspace is touched.

import Foundation
import CoreGraphics
import CoreText
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Mac self-owned runtime projects and attachments")
struct WorkspaceLeaseAndAttachmentsTests {

    @Test("registerWorkspace is idempotent per resolved local root path")
    func registerWorkspaceIsIdempotent() async throws {
        try await withSelfCoreFixture { fixture in
            let bookmark = try fixture.workspaceRoot.bookmarkData()
            async let initial = fixture.runtime.registerWorkspace(name: "Fixture Project", rootBookmark: bookmark)
            async let concurrent = fixture.runtime.registerWorkspace(name: "Fixture Project", rootBookmark: bookmark)
            let (first, same) = try await (initial, concurrent)
            let second = try await fixture.runtime.registerWorkspace(
                name: "Fixture Project Renamed",
                rootBookmark: bookmark
            )
            #expect(first.id == same.id)
            #expect(first.id == second.id)
            #expect(first.name == "Fixture Project")
            let listed = try await fixture.runtime.workspaces()
            #expect(listed.filter { $0.id == first.id }.count == 1)
            #expect(try await fixture.runtime.workspace(id: first.id)?.name == "Fixture Project")
        }
    }

    @Test("An unreadable or stale workspace bookmark cannot register")
    func registerWorkspaceRejectsBadBookmarks() async throws {
        try await withSelfCoreFixture { fixture in
            let error = await selfCoreError {
                _ = try await fixture.runtime.registerWorkspace(name: "Broken", rootBookmark: Data())
            }
            #expect(error?.code == "invalidRequest")
        }
    }

    // MARK: - Durable attachments

    @Test("An image attachment is durable, verified, and reaches the provider")
    func imageAttachmentReachesProvider() async throws {
        try await withSelfCoreFixture { fixture in
            let attachment = try fixture.makeImageAttachment()
            let (provider, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "I can see the image.")),
                .completed(.init(stopReason: .endTurn)),
            ]], capabilities: [.text, .vision])
            let base = fixture.newConversationRequest(goal: "Describe the attachment")
            let request = FloeMacSelfSessionRequest(
                conversationID: base.conversationID,
                workspaceID: base.workspaceID,
                conversationTitle: base.conversationTitle,
                goal: base.goal,
                mode: base.mode,
                context: base.context,
                attachments: [attachment]
            )
            let handle = try await fixture.runtime.startSession(request, provider: provider)
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)

            // The provider saw the image bytes in the current user message.
            let lastRequest = try #require(adapter.requests.last)
            let userContent = lastRequest.contentMessages
                .last { $0.role == "user" }?.content ?? []
            #expect(userContent.contains { part in
                if case .imageData(let mimeType, let base64) = part {
                    return mimeType == "image/png"
                        && Data(base64Encoded: base64) == SelfCoreFixture.fixturePNGBytes
                }
                return false
            })

            // The durable user turn carries the verified attachment part.
            let messages = try await handle.durableMessages()
            let userMessage = try #require(messages.last { $0.role == "user" })
            #expect(userMessage.parts.count == 2)
            #expect(userMessage.parts[1].kind == .image)
            #expect(userMessage.parts[1].attachmentID == attachment.id)
            #expect(userMessage.parts[1].metadata["name"] == attachment.displayName)
            _ = try await handle.close()
        }
    }

    @Test("Small text is sent only on the wire; over-limit text stays as a reference", arguments: [true, false])
    func documentAttachmentVisibility(eligible: Bool) async throws {
        try await withSelfCoreFixture { fixture in
            let marker = "fixture document body"
            let attachment = try fixture.makeDocumentAttachment(
                contents: eligible ? marker : marker + String(repeating: "x", count: 9_000))
            let (provider, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Noted.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let base = fixture.newConversationRequest(goal: "Keep the notes attached")
            let request = FloeMacSelfSessionRequest(
                conversationID: base.conversationID,
                workspaceID: base.workspaceID,
                conversationTitle: base.conversationTitle,
                goal: base.goal,
                mode: base.mode,
                context: base.context,
                attachments: [attachment]
            )
            let handle = try await fixture.runtime.startSession(request, provider: provider)
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)

            let lastRequest = try #require(adapter.requests.last)
            var containsBody = false
            for message in lastRequest.contentMessages where message.role == "user" {
                for part in message.content {
                    if case .text(let text) = part, text.contains(marker) { containsBody = true }
                    if case .imageData = part { Issue.record("Document unexpectedly became an image") }
                }
            }
            #expect(containsBody == eligible)

            // The durable turn keeps the file reference for the task history.
            let messages = try await handle.durableMessages()
            let userMessage = try #require(messages.last { $0.role == "user" })
            #expect(userMessage.content == base.goal)
            #expect(userMessage.parts.count == 2)
            #expect(userMessage.parts[1].kind == .file)
            #expect(userMessage.parts[1].attachmentID == attachment.id)
            _ = try await handle.close()
        }
    }

    @Test("A PDF attachment reveals its text only to the current model request")
    func pdfAttachmentReachesProvider() async throws {
        try await withSelfCoreFixture { fixture in
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
            var paper = CGRect(x: 0, y: 0, width: 300, height: 300)
            let page = try #require(CGContext(consumer: consumer, mediaBox: &paper, nil))
            page.beginPDFPage(nil)
            let marker = "Synthetic PDF page text"
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: marker, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            ]))
            page.textPosition = CGPoint(x: 24, y: 120)
            CTLineDraw(line, page)
            page.endPDFPage()
            page.closePDF()
            let url = fixture.root.appendingPathComponent("fixture.pdf")
            let bytes = data as Data
            try bytes.write(to: url)
            let attachment = FloeMacSelfSessionAttachment(kind: .document, displayName: url.lastPathComponent,
                uti: "com.adobe.pdf", byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes),
                bookmark: try url.bookmarkData())
            let (binding, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "PDF fixture response.")), .completed(.init(stopReason: .endTurn))
            ]])
            let handle = try await fixture.runtime.startSession(
                .init(goal: "Read the attached PDF", mode: .chat, attachments: [attachment]), provider: binding)
            #expect(await handle.waitForTerminal(timeout: 15)?.confirmed == true)
            let sent = try #require(adapter.requests.first)
            #expect(sent.effectiveMessages.contains { message in
                message.role == "user" && message.content.contains { part in
                    if case .text(let text) = part { return text.contains(marker) }
                    return false
                }
            })
            let messages = try await handle.durableMessages()
            let userMessage = try #require(messages.first { $0.role == "user" })
            #expect(userMessage.content == "Read the attached PDF")
            #expect(userMessage.parts.contains { $0.attachmentID == attachment.id && $0.kind == .file })
            _ = try await handle.close()
        }
    }

    @Test("A deflated Word attachment reaches the provider as text")
    func wordAttachmentReachesProvider() async throws {
        try await withSelfCoreFixture { fixture in
            // A ZIP fixture containing one word/document.xml member with a single text paragraph.
            let bytes = try #require(Data(base64Encoded: """
                UEsDBBQAAAAIAAcQdF1wSJ1ongAAANMAAAARAAAAd29yZC9kb2N1bWVudC54bWxFjkkOwjAMRa8SZU9TWCBUd
                dhxAUCsQ2KaSM0gx3S4PUlZsHmW9b+f3A6rm9gMmGzwHT9WNWfgVdDWjx1/3K+HCx/6dml0UB8Hnlju+9QsHT
                dEsREiKQNOpipE8Dl7B3SS8oqjWALqiEFBSlnnJnGq67Nw0npelK+gtzJjARZQf9s8GSCr2DMfM4nK2BkYwUq
                tKIVC3Bl3/iTi/2D/BVBLAQIUAxQAAAAIAAcQdF1wSJ1ongAAANMAAAARAAAAAAAAAAAAAACAAQAAAAB3b3Jk
                L2RvY3VtZW50LnhtbFBLBQYAAAAAAQABAD8AAADNAAAAAAA=
                """, options: .ignoreUnknownCharacters))
            let url = fixture.root.appendingPathComponent("fixture.docx")
            try bytes.write(to: url)
            let attachment = FloeMacSelfSessionAttachment(kind: .document, displayName: url.lastPathComponent,
                uti: "org.openxmlformats.wordprocessingml.document", byteCount: bytes.count,
                sha256: FloeDigest.sha256Hex(bytes), bookmark: try url.bookmarkData())
            let (binding, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Word fixture response.")), .completed(.init(stopReason: .endTurn))
            ]])
            let handle = try await fixture.runtime.startSession(
                .init(goal: "Read the Word attachment", mode: .chat, attachments: [attachment]), provider: binding)
            #expect(await handle.waitForTerminal(timeout: 15)?.confirmed == true)
            let request = try #require(adapter.requests.first)
            #expect(request.effectiveMessages.contains { message in
                message.role == "user" && message.content.contains { part in
                    if case .text(let text) = part { return text.contains("Synthetic Word archive text") }
                    return false
                }
            })
            _ = try await handle.close()
        }
    }

    @Test("An unreadable formatted attachment fails before a request or visible task is created")
    func malformedDocumentIsRecoverable() async throws {
        try await withSelfCoreFixture { fixture in
            let url = fixture.root.appendingPathComponent("fixture.docx")
            let bytes = Data("not a Word archive".utf8)
            try bytes.write(to: url)
            let attachment = FloeMacSelfSessionAttachment(kind: .document, displayName: url.lastPathComponent,
                uti: "org.openxmlformats.wordprocessingml.document", byteCount: bytes.count,
                sha256: FloeDigest.sha256Hex(bytes), bookmark: try url.bookmarkData())
            let (binding, adapter) = fixture.makeProvider(scripts: [])
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(.init(goal: "Read it", mode: .chat, attachments: [attachment]),
                                                          provider: binding)
            }
            #expect(error?.code == "attachmentUnreadable")
            #expect(adapter.requests.isEmpty)
            #expect(try await fixture.runtime.conversations().isEmpty)
        }
    }

    @Test("An attachment whose bytes change after staging is dropped, not sent")
    func tamperedImageAttachmentIsDropped() async throws {
        try await withSelfCoreFixture { fixture in
            let attachment = try fixture.makeImageAttachment(named: "mutating.png")
            let (provider, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Answered without the image.")),
                .completed(.init(stopReason: .endTurn)),
            ]], capabilities: [.text, .vision])
            // Mutate the file between staging and start: the digest persisted
            // at staging no longer matches the bytes on disk.
            let mutated = Data(repeating: 0x41, count: 64)
            let url = fixture.root.appendingPathComponent("mutating.png")
            try mutated.write(to: url)
            #expect(FloeDigest.sha256Hex(mutated) != attachment.sha256)

            let base = fixture.newConversationRequest(goal: "Try the mutated image")
            let request = FloeMacSelfSessionRequest(
                conversationID: base.conversationID,
                workspaceID: base.workspaceID,
                conversationTitle: base.conversationTitle,
                goal: base.goal,
                mode: base.mode,
                context: base.context,
                attachments: [attachment]
            )
            let handle = try await fixture.runtime.startSession(request, provider: provider)
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let lastRequest = try #require(adapter.requests.last)
            let userContent = lastRequest.contentMessages
                .last { $0.role == "user" }?.content ?? []
            #expect(!userContent.contains { part in
                if case .imageData = part { return true }
                return false
            })
            _ = try await handle.close()
        }
    }

    @Test("Resuming a conversation keeps old image attachments as records without re-reading them")
    func resumedHistoryNeverReReadsOldAttachments() async throws {
        try await withSelfCoreFixture { fixture in
            // Turn 1 carries an image that is later deleted; its durable
            // attachment record remains part of the task history.
            let attachment = try fixture.makeImageAttachment(named: "turn-one.png")
            let (firstProvider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "First answer.")),
                .completed(.init(stopReason: .endTurn)),
            ]], capabilities: [.text, .vision])
            let base = fixture.newConversationRequest(goal: "First turn with an image")
            let firstRequest = FloeMacSelfSessionRequest(
                conversationID: base.conversationID,
                workspaceID: base.workspaceID,
                conversationTitle: base.conversationTitle,
                goal: base.goal,
                mode: base.mode,
                context: base.context,
                attachments: [attachment]
            )
            let first = try await fixture.runtime.startSession(firstRequest, provider: firstProvider)
            let firstTerminal = try #require(await first.waitForTerminal(timeout: 15))
            #expect(firstTerminal.confirmed)
            _ = try await first.close()
            let conversationID = first.identity.conversationID

            // Delete the backing file: any history re-read of the mutable
            // bookmark would fail closed, but it must not even be attempted.
            try FileManager.default.removeItem(
                at: fixture.root.appendingPathComponent("turn-one.png")
            )

            let (secondProvider, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Second answer.")),
                .completed(.init(stopReason: .endTurn)),
            ]], capabilities: [.text, .vision])
            let second = try await fixture.runtime.startSession(
                fixture.continuationRequest(conversationID: conversationID, goal: "Second plain turn"),
                provider: secondProvider
            )
            let secondTerminal = try #require(await second.waitForTerminal(timeout: 15))
            #expect(secondTerminal.confirmed)
            let request = try #require(adapter.requests.last)
            for message in request.contentMessages {
                #expect(!message.content.contains { part in
                    if case .imageData = part { return true }
                    return false
                })
            }
            // The old attachment record survives on the durable user turn.
            let history = try await fixture.runtime.conversationMessages(conversationID: conversationID)
            let firstUser = try #require(history.first { $0.role == "user" })
            #expect(firstUser.parts.contains { $0.kind == .image && $0.attachmentID == attachment.id })
            _ = try await second.close()
        }
    }

    @Test("Invalid attachment metadata fails before any durable admission")
    func invalidAttachmentMetadataFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let attachment = try fixture.makeDocumentAttachment()
            let invalid = FloeMacSelfSessionAttachment(
                id: attachment.id,
                kind: attachment.kind,
                displayName: attachment.displayName,
                uti: attachment.uti,
                byteCount: attachment.byteCount,
                sha256: "not-a-digest",
                bookmark: attachment.bookmark
            )
            let (provider, adapter) = fixture.makeProvider(scripts: [])
            let base = fixture.newConversationRequest(goal: "Bad digest")
            let request = FloeMacSelfSessionRequest(
                conversationID: base.conversationID,
                workspaceID: base.workspaceID,
                conversationTitle: base.conversationTitle,
                goal: base.goal,
                mode: base.mode,
                context: base.context,
                attachments: [invalid]
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: provider)
            }
            #expect(error?.code == "invalidRequest")
            #expect(adapter.requests.isEmpty)
            #expect(try await fixture.runtime.nonTerminalRuns().isEmpty)
        }
    }

    // MARK: - Workspace move

    @Test("Moving a task to a project workspace changes membership and preserves history")
    func moveToProjectPreservesHistory() async throws {
        try await withSelfCoreFixture { fixture in
            let projectID = try await fixture.createWorkspace(named: "Move Target")
            let attachment = try fixture.makeImageAttachment(named: "history.png")
            let (provider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Answer with the image.")),
                .completed(.init(stopReason: .endTurn)),
            ]], capabilities: [.text, .vision])
            let base = fixture.newConversationRequest(goal: "First turn", title: "Moving Task")
            let request = FloeMacSelfSessionRequest(
                conversationID: base.conversationID,
                workspaceID: base.workspaceID,
                conversationTitle: base.conversationTitle,
                goal: base.goal,
                mode: base.mode,
                context: base.context,
                attachments: [attachment]
            )
            let handle = try await fixture.runtime.startSession(request, provider: provider)
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let conversationID = handle.identity.conversationID
            let privateWorkspaceID = handle.identity.workspaceID
            _ = try await handle.close()

            // History before the move: one run, user+assistant turns, and a
            // durable image part on the user turn.
            let runsBefore = try await fixture.runtime.recentRuns(conversationID: conversationID)
            let messagesBefore = try await fixture.runtime.conversationMessages(conversationID: conversationID)
            #expect(runsBefore.count == 1)
            #expect(messagesBefore.contains { $0.role == "user" })

            let owner = try await fixture.runtime.moveConversation(
                id: conversationID, toWorkspaceID: projectID
            )
            #expect(owner.id == projectID)
            #expect(owner.kind == .project)
            #expect(try await fixture.runtime.workspaceForConversation(conversationID)?.id == projectID)

            // Only membership changed: run and message identities, and the
            // attachment record, are untouched by the move.
            let runsAfter = try await fixture.runtime.recentRuns(conversationID: conversationID)
            let messagesAfter = try await fixture.runtime.conversationMessages(conversationID: conversationID)
            #expect(runsAfter.map(\.id) == runsBefore.map(\.id))
            #expect(messagesAfter.map(\.id) == messagesBefore.map(\.id))
            let userAfter = try #require(messagesAfter.first { $0.role == "user" })
            #expect(userAfter.parts.contains {
                $0.kind == .image && $0.attachmentID == attachment.id
            })

            // The vacated per-task private workspace row is preserved with
            // its files; a later detach reuses it instead of re-creating it.
            let preserved = try await fixture.runtime.workspace(id: privateWorkspaceID)
            #expect(preserved?.kind == .privateTask)
            #expect(preserved?.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)")
        }
    }

    @Test("Moving away to a project and detaching back reuses the original private workspace")
    func moveAwayAndBackReusesPrivateWorkspace() async throws {
        try await withSelfCoreFixture { fixture in
            let projectID = try await fixture.createWorkspace(named: "Away Project")
            let (provider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Turn one.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Turn one", title: "Round Trip"),
                provider: provider
            )
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let conversationID = handle.identity.conversationID
            let privateWorkspaceID = handle.identity.workspaceID
            _ = try await handle.close()
            let messagesBefore = try await fixture.runtime.conversationMessages(conversationID: conversationID)

            // Away: the task joins the project; its private workspace row
            // stays behind, keyed by this task's id.
            let projectOwner = try await fixture.runtime.moveConversation(
                id: conversationID, toWorkspaceID: projectID
            )
            #expect(projectOwner.id == projectID)
            #expect(try await fixture.runtime.workspace(id: privateWorkspaceID) != nil)

            // Back: detaching reuses the preserved private workspace row
            // (same id, same task-keyed relative path) — no second row is
            // created and the original private files stay attached to it.
            let detached = try await fixture.runtime.moveConversation(
                id: conversationID, toWorkspaceID: nil
            )
            #expect(detached.id == privateWorkspaceID)
            #expect(detached.kind == .privateTask)
            #expect(detached.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)")
            #expect(try await fixture.runtime.workspaceForConversation(conversationID)?.id == privateWorkspaceID)

            // The round trip never touched history.
            let messagesAfter = try await fixture.runtime.conversationMessages(conversationID: conversationID)
            #expect(messagesAfter.map(\.id) == messagesBefore.map(\.id))
        }
    }
}
