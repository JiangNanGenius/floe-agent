// SPDX-License-Identifier: MPL-2.0
//
// Project registration and durable attachment tests for the Mac
// self-owned runtime. Every root is a fresh 0700 temporary directory; no
// user database, Keychain item or workspace is touched.

import Foundation
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

    @Test("A document attachment stays a durable reference and never reaches the model")
    func documentAttachmentIsReferenceOnly() async throws {
        try await withSelfCoreFixture { fixture in
            let attachment = try fixture.makeDocumentAttachment()
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

            // No image/content part reaches the provider for a document.
            let lastRequest = try #require(adapter.requests.last)
            for message in lastRequest.contentMessages where message.role == "user" {
                #expect(!message.content.contains { part in
                    if case .imageData = part { return true }
                    return false
                })
            }

            // The durable turn keeps the file reference for the task history.
            let messages = try await handle.durableMessages()
            let userMessage = try #require(messages.last { $0.role == "user" })
            #expect(userMessage.parts.count == 2)
            #expect(userMessage.parts[1].kind == .file)
            #expect(userMessage.parts[1].attachmentID == attachment.id)
            _ = try await handle.close()
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
}
