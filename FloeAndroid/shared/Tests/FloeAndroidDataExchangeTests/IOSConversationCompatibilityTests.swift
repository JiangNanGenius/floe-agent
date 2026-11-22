// SPDX-License-Identifier: MPL-2.0
//
// iOS conversation-data compatibility — store round-trip evidence.
//
// Android alone adapts to the UNCHANGED current iOS data model at Git object
// 7897f9c10bb70049bf5438cf3360694e628ceb1f:
//   * FloeAgent/Sources/FloeModels/AgentThread.swift (MessagePart.Kind now
//     carries `interactive` on Android, byte-identical to the iOS source)
//   * FloeAgent/Sources/FloePersistence/ConversationStore.swift
//   * FloeAgent/Sources/FloePersistence/RunStore.swift
//   * FloeDesktopSync/Sources/FloeDesktopSync/CanonicalMessageFeed.swift
//
// The shared v1–v46 migration chain is byte-identical on both platforms and
// `message_parts.kind` is plain TEXT with no CHECK constraint, so iOS-shaped
// rows — including `interactive` parts — need NO data migration and no
// database reset: the normal GRDB stores decode them through the restored
// enum case. Android's additive v55 migration (V55ConversationContinuity)
// additionally preserves the iOS conversations metadata (`visibility`,
// `editor_owner_*`) in the real table with iOS-defaulted columns, so
// iOS-originated hidden / editor-owned rows keep their semantics instead of
// being flattened into ordinary chats. These tests prove the contract
// against (a) a fixed iOS-derived fixture written and read back through the
// normal stores and (b) raw pre-update Android rows laid into a database
// built by the EXISTING Android migration chain. The canonical comparison
// projection below is TEST-ONLY; no sync transport and no import UI is
// introduced.
//
// Boundaries (unchanged by this package): `temporary` conversations stay
// RAM-only; C07 backup duplicate/restore semantics are untouched.
//
// Integration note: this suite exercises the real stores, so the
// FloeAndroidDataExchangeTests target needs FloeModels, FloePersistence and
// GRDB on its dependency list. Package.swift is outside this lane's assigned
// paths; the integration owner adds those three entries.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence

final class IOSConversationCompatibilityTests: XCTestCase {

    // MARK: - Fixed iOS-derived fixture

    /// Deterministic, fully synthetic fixture derived from the fixed iOS
    /// definitions at 7897f9c1: an ordinary pinned conversation and a Notes
    /// conversation, a user message, an assistant message whose parts are
    /// [text, interactive, image-with-attachment] in a specific order, the
    /// attachment identity, one run and its receipt stream (status /
    /// toolRequest / toolResult / usage / terminal) plus a usage point.
    private static let fixtureJSON = """
    {
      "format": "floe.ios-conversation-fixture",
      "formatVersion": 1,
      "sourceCommit": "7897f9c10bb70049bf5438cf3360694e628ceb1f",
      "conversations": [
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "title": "Quarterly trend chart",
          "createdAt": "2026-11-20T09:00:00.000Z",
          "updatedAt": "2026-11-20T09:41:07.123Z",
          "titleOrigin": "automatic",
          "archivedAt": null,
          "purpose": "ordinary",
          "pinnedAt": "2026-11-20T09:41:07.123Z"
        },
        {
          "id": "22222222-2222-4222-8222-222222222222",
          "title": "Reading notes",
          "createdAt": "2026-11-18T10:00:00.000Z",
          "updatedAt": "2026-11-18T10:05:00.000Z",
          "titleOrigin": "manual",
          "archivedAt": "2026-11-19T11:00:00.000Z",
          "purpose": "notes",
          "pinnedAt": null
        }
      ],
      "messages": [
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "conversationID": "11111111-1111-4111-8111-111111111111",
          "role": "user",
          "content": "Please chart the Q3 trend interactively.",
          "createdAt": "2026-11-20T09:40:00.000Z",
          "runID": "33333333-3333-4333-8333-333333333333",
          "parts": [
            {
              "id": "77777777-7777-4777-8777-777777777777",
              "index": 0,
              "kind": "text",
              "text": "Please chart the Q3 trend interactively.",
              "attachmentID": null,
              "metadata": {},
              "createdAt": "2026-11-20T09:40:00.000Z"
            }
          ]
        },
        {
          "id": "55555555-5555-4555-8555-555555555555",
          "conversationID": "11111111-1111-4111-8111-111111111111",
          "role": "assistant",
          "content": "Here is the interactive chart.\n\nSee the source image.",
          "createdAt": "2026-11-20T09:41:07.123Z",
          "runID": "33333333-3333-4333-8333-333333333333",
          "parts": [
            {
              "id": "88888888-8888-4888-8888-888888888888",
              "index": 0,
              "kind": "text",
              "text": "Here is the interactive chart.",
              "attachmentID": null,
              "metadata": {},
              "createdAt": "2026-11-20T09:41:07.000Z"
            },
            {
              "id": "99999999-9999-4999-8999-999999999999",
              "index": 1,
              "kind": "interactive",
              "text": "{\\"fallbackText\\":\\"See the source image.\\",\\"html\\":\\"<div id=\\\\\\"chart\\\\\\"></div>\\",\\"title\\":\\"Q3 trend\\"}",
              "attachmentID": null,
              "metadata": { "requestDigest": "f00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00d" },
              "createdAt": "2026-11-20T09:41:07.100Z"
            },
            {
              "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "index": 2,
              "kind": "image",
              "text": null,
              "attachmentID": "66666666-6666-4666-8666-666666666666",
              "metadata": { "name": "q3-trend.png" },
              "createdAt": "2026-11-20T09:41:07.120Z"
            }
          ]
        }
      ],
      "attachments": [
        {
          "id": "66666666-6666-4666-8666-666666666666",
          "conversationID": "11111111-1111-4111-8111-111111111111",
          "messageID": "55555555-5555-4555-8555-555555555555",
          "kind": "image",
          "displayName": "q3-trend.png",
          "uti": "public.png",
          "byteCount": 20480,
          "sha256": "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c",
          "storage": "applicationSupport",
          "relativePath": "attachments/q3-trend.png",
          "createdAt": "2026-11-20T09:41:07.120Z"
        }
      ],
      "runs": [
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "conversationID": "11111111-1111-4111-8111-111111111111",
          "state": "completed",
          "goal": "Chart the Q3 trend interactively",
          "startedAt": "2026-11-20T09:40:01.000Z",
          "endedAt": "2026-11-20T09:41:07.123Z",
          "goalID": null,
          "providerID": null,
          "modelID": null,
          "providerName": "Example Provider",
          "modelName": "example-model",
          "conversationMode": "chat"
        }
      ],
      "runEvents": [
        {
          "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          "runID": "33333333-3333-4333-8333-333333333333",
          "sequence": 1,
          "kind": "status",
          "payload": "{\\"status\\":\\"running\\"}",
          "createdAt": "2026-11-20T09:40:01.000Z"
        },
        {
          "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          "runID": "33333333-3333-4333-8333-333333333333",
          "sequence": 2,
          "kind": "toolRequest",
          "payload": "{\\"tool\\":\\"chart.render\\",\\"status\\":\\"ok\\"}",
          "createdAt": "2026-11-20T09:40:02.000Z"
        },
        {
          "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          "runID": "33333333-3333-4333-8333-333333333333",
          "sequence": 3,
          "kind": "toolResult",
          "payload": "{\\"status\\":\\"ok\\",\\"output\\":\\"chart rendered\\"}",
          "createdAt": "2026-11-20T09:41:00.000Z"
        },
        {
          "id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
          "runID": "33333333-3333-4333-8333-333333333333",
          "sequence": 4,
          "kind": "usage",
          "payload": "{\\"inputTokens\\":1200,\\"outputTokens\\":300}",
          "createdAt": "2026-11-20T09:41:07.000Z"
        },
        {
          "id": "ffffffff-ffff-4fff-8fff-ffffffffffff",
          "runID": "33333333-3333-4333-8333-333333333333",
          "sequence": 5,
          "kind": "terminal",
          "payload": "{\\"status\\":\\"completed\\"}",
          "createdAt": "2026-11-20T09:41:07.123Z"
        }
      ],
      "runUsage": [
        {
          "id": "abababab-abab-4bab-8bab-abababababab",
          "runID": "33333333-3333-4333-8333-333333333333",
          "inputTokens": 1200,
          "outputTokens": 300,
          "cacheReadTokens": 400,
          "cacheMissTokens": null,
          "cacheWriteTokens": 50,
          "reasoningTokens": 90,
          "totalDurationMs": 66123,
          "timeToFirstTokenMs": 890,
          "tokensPerSecond": 12.5,
          "isEstimated": false,
          "costEstimate": "0.0042",
          "recordedAt": "2026-11-20T09:41:07.000Z"
        }
      ],
      "runErrors": []
    }
    """

    // MARK: - Test-only canonical comparison projection
    //
    // Mirrors the CanonicalMessageFeed.Message/Part projection semantics
    // (id, conversationID, role, content, createdAt, runID, parts ordered by
    // index with kind/text/attachmentID/metadata). TEST-ONLY: production code
    // never projects through this shape.

    private struct FeedPart: Equatable {
        var id: UUID
        var index: Int
        var kind: String
        var text: String?
        var attachmentID: UUID?
        var metadata: [String: String]
        var createdAt: Date
    }

    private struct FeedMessage: Equatable {
        var id: UUID
        var conversationID: UUID
        var role: String
        var content: String
        var createdAt: Date
        var runID: UUID?
        var parts: [FeedPart]
    }

    private func project(_ message: PersistedMessage) -> FeedMessage {
        FeedMessage(
            id: message.id,
            conversationID: message.conversationID,
            role: message.role,
            content: message.content,
            createdAt: message.createdAt,
            runID: message.runID,
            parts: message.parts.map {
                FeedPart(id: $0.id, index: $0.partIndex, kind: $0.kind.rawValue,
                         text: $0.text, attachmentID: $0.attachmentID,
                         metadata: $0.metadata, createdAt: $0.createdAt)
            })
    }

    // MARK: - Fixture decoding (dates as ISO-8601 strings, like the stores)

    private struct Fixture: Decodable {
        struct Conversation: Decodable {
            var id: UUID
            var title: String
            var createdAt: String
            var titleOrigin: String
            var archivedAt: String?
            var purpose: String
            var pinnedAt: String?
        }
        struct Part: Decodable {
            var id: UUID
            var index: Int
            var kind: String
            var text: String?
            var attachmentID: UUID?
            var metadata: [String: String]
            var createdAt: String
        }
        struct Message: Decodable {
            var id: UUID
            var conversationID: UUID
            var role: String
            var content: String
            var createdAt: String
            var runID: UUID?
            var parts: [Part]
        }
        struct Attachment: Decodable {
            var id: UUID
            var conversationID: UUID?
            var messageID: UUID?
            var kind: String
            var displayName: String
            var uti: String
            var byteCount: Int
            var sha256: String
            var storage: String
            var relativePath: String?
            var createdAt: String
        }
        struct Run: Decodable {
            var id: UUID
            var conversationID: UUID
            var state: String
            var goal: String
            var startedAt: String
            var endedAt: String?
            var providerName: String?
            var modelName: String?
            var conversationMode: String?
        }
        struct RunEvent: Decodable {
            var id: UUID
            var runID: UUID
            var sequence: Int
            var kind: String
            var payload: String
            var createdAt: String
        }
        struct RunUsage: Decodable {
            var id: UUID
            var runID: UUID
            var inputTokens: Int
            var outputTokens: Int
            var cacheReadTokens: Int?
            var cacheWriteTokens: Int?
            var reasoningTokens: Int?
            var totalDurationMs: Int?
            var timeToFirstTokenMs: Int?
            var tokensPerSecond: Double?
            var isEstimated: Bool
            var costEstimate: String?
            var recordedAt: String
        }
        var conversations: [Conversation]
        var messages: [Message]
        var attachments: [Attachment]
        var runs: [Run]
        var runEvents: [RunEvent]
        var runUsage: [RunUsage]
    }

    private func decodeFixture() throws -> Fixture {
        let data = try XCTUnwrap(Self.fixtureJSON.data(using: .utf8))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// Mirrors PersistenceCodec.decodeDate (fractional or whole-second).
    private func fixtureDate(_ raw: String, _ file: StaticString = #filePath, _ line: UInt = #line) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(standard.date(from: raw), "invalid fixture date \(raw)", file: file, line: line)
    }

    // MARK: - 1. Fixed iOS fixture through the normal stores (GRDB round-trip)

    func testIOSFixtureRoundTripsThroughNormalStores() async throws {
        let fixture = try decodeFixture()
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let conversations = SQLiteConversationStore(database: manager)
        let runs = SQLiteRunStore(database: manager)

        // Write through the normal stores.
        for conversation in fixture.conversations {
            try await conversations.saveConversation(ConversationRecord(
                id: conversation.id,
                title: conversation.title,
                createdAt: try fixtureDate(conversation.createdAt),
                updatedAt: try fixtureDate(conversation.createdAt),
                titleOrigin: try XCTUnwrap(ConversationTitleOrigin(rawValue: conversation.titleOrigin)),
                archivedAt: try conversation.archivedAt.map(fixtureDate),
                purpose: try XCTUnwrap(ConversationPurpose(rawValue: conversation.purpose)),
                pinnedAt: try conversation.pinnedAt.map(fixtureDate)))
        }
        for message in fixture.messages {
            var parts: [MessagePart] = []
            for part in message.parts {
                parts.append(MessagePart(
                    id: part.id,
                    messageID: message.id,
                    partIndex: part.index,
                    kind: try XCTUnwrap(MessagePart.Kind(rawValue: part.kind),
                                        "fixture part kind \(part.kind) must decode"),
                    text: part.text,
                    attachmentID: part.attachmentID,
                    metadata: part.metadata,
                    createdAt: try fixtureDate(part.createdAt)))
            }
            try await conversations.appendMessage(PersistedMessage(
                id: message.id,
                conversationID: message.conversationID,
                role: message.role,
                content: message.content,
                createdAt: try fixtureDate(message.createdAt),
                parts: parts,
                runID: message.runID))
        }
        for attachment in fixture.attachments {
            try await conversations.saveAttachment(AttachmentRef(
                id: attachment.id,
                conversationID: attachment.conversationID,
                messageID: attachment.messageID,
                kind: try XCTUnwrap(AttachmentRef.Kind(rawValue: attachment.kind)),
                displayName: attachment.displayName,
                uti: attachment.uti,
                byteCount: attachment.byteCount,
                sha256: attachment.sha256,
                storage: try XCTUnwrap(AttachmentRef.Storage(rawValue: attachment.storage)),
                relativePath: attachment.relativePath,
                createdAt: try fixtureDate(attachment.createdAt)))
        }
        for run in fixture.runs {
            try await runs.saveRun(RunRecord(
                id: run.id,
                conversationID: run.conversationID,
                state: run.state,
                goal: run.goal,
                startedAt: try fixtureDate(run.startedAt),
                endedAt: try run.endedAt.map(fixtureDate),
                providerName: run.providerName,
                modelName: run.modelName,
                conversationMode: run.conversationMode))
        }
        for event in fixture.runEvents {
            _ = try await runs.appendEvent(
                runID: event.runID,
                kind: try XCTUnwrap(RunEventRecord.Kind(rawValue: event.kind)),
                payloadJSON: event.payload)
        }
        for usage in fixture.runUsage {
            try await runs.recordUsage(RunUsageRecord(
                id: usage.id,
                runID: usage.runID,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: usage.reasoningTokens,
                totalDurationMs: usage.totalDurationMs,
                timeToFirstTokenMs: usage.timeToFirstTokenMs,
                tokensPerSecond: usage.tokensPerSecond,
                isEstimated: usage.isEstimated,
                costEstimate: usage.costEstimate,
                recordedAt: try fixtureDate(usage.recordedAt)))
        }

        // Read back through the normal stores and compare projections.
        let mainID = fixture.conversations[0].id
        let readBack = try await conversations.messages(conversationID: mainID)
        let expected = fixture.messages.filter { $0.conversationID == mainID }
        XCTAssertEqual(readBack.map(project), expected.map { message in
            FeedMessage(
                id: message.id, conversationID: message.conversationID,
                role: message.role, content: message.content,
                createdAt: try! fixtureDate(message.createdAt),
                runID: message.runID,
                parts: message.parts.map { part in
                    FeedPart(id: part.id, index: part.index, kind: part.kind,
                             text: part.text, attachmentID: part.attachmentID,
                             metadata: part.metadata,
                             createdAt: try! fixtureDate(part.createdAt))
                })
        })

        // Per-message part order and the interactive kind survive exactly.
        let assistant = try XCTUnwrap(readBack.first { $0.role == "assistant" })
        XCTAssertEqual(assistant.parts.map(\.partIndex), [0, 1, 2])
        XCTAssertEqual(assistant.parts.map(\.kind.rawValue), ["text", "interactive", "image"])
        XCTAssertEqual(assistant.parts[1].text.map { $0.contains("\"fallbackText\"") }, true)
        XCTAssertEqual(assistant.parts[1].metadata["requestDigest"],
                       "f00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00d")

        // Attachment file identity and part linkage.
        let attachmentID = try XCTUnwrap(assistant.parts[2].attachmentID)
        let attachment = try await conversations.attachment(id: attachmentID)
        XCTAssertEqual(attachment?.sha256,
                       "b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c")
        XCTAssertEqual(attachment?.relativePath, "attachments/q3-trend.png")
        XCTAssertEqual(attachment?.byteCount, 20480)
        XCTAssertEqual(attachment?.storage, .applicationSupport)
        XCTAssertEqual(attachment?.messageID, assistant.id)

        // Conversation semantics: purpose, pin, title origin.
        let conversation = try await conversations.conversation(id: mainID)
        XCTAssertEqual(conversation?.purpose, .ordinary)
        XCTAssertEqual(conversation?.isPinned, true)
        XCTAssertEqual(conversation?.titleOrigin, .automatic)
        let notes = try await conversations.conversation(id: fixture.conversations[1].id)
        XCTAssertEqual(notes?.purpose, .notes)
        XCTAssertEqual(notes?.isPinned, false)
        XCTAssertEqual(notes?.archivedAt, try fixtureDate("2026-11-19T11:00:00.000Z"))
        XCTAssertEqual(notes?.visibility, .normal)
        XCTAssertEqual(notes?.editorOwnership, nil)

        // Run receipts round-trip in order.
        let runID = try XCTUnwrap(fixture.runs.first?.id)
        let events = try await runs.events(runID: runID)
        XCTAssertEqual(events.map(\.kind.rawValue),
                       ["status", "toolRequest", "toolResult", "usage", "terminal"])
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(events.first { $0.kind == .toolResult }?.payloadJSON,
                       "{\"status\":\"ok\",\"output\":\"chart rendered\"}")
        let usage = try await runs.usage(runID: runID)
        XCTAssertEqual(usage.first?.inputTokens, 1200)
        XCTAssertEqual(usage.first?.cacheReadTokens, 400)

        // Idempotent re-append of the same message does not duplicate parts.
        let before = try await conversations.parts(messageID: assistant.id)
        try await conversations.appendMessage(assistant)
        let after = try await conversations.parts(messageID: assistant.id)
        XCTAssertEqual(before, after)
    }

    // MARK: - 2. Initial INSERT persists non-default presentation metadata;
    //            conflict updates leave it to the dedicated setters

    func testInitialInsertPresentsTitleOriginArchivePinAndConflictRetention() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let store = SQLiteConversationStore(database: manager)
        let id = UUID()
        let archivedAt = try fixtureDate("2026-11-21T08:30:00.000Z")
        let pinnedAt = try fixtureDate("2026-11-21T09:00:00.000Z")

        // Synthetic non-default record: manual title origin, archived, pinned.
        try await store.saveConversation(ConversationRecord(
            id: id, title: "Draft", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            titleOrigin: .manual, archivedAt: archivedAt,
            purpose: .ordinary, pinnedAt: pinnedAt))
        let inserted = try await store.conversation(id: id)
        XCTAssertEqual(inserted?.titleOrigin, .manual)
        XCTAssertEqual(inserted?.archivedAt, archivedAt)
        XCTAssertEqual(inserted?.pinnedAt, pinnedAt)
        XCTAssertEqual(inserted?.isPinned, true)
        XCTAssertEqual(inserted?.isVisibleInOrdinaryList, false) // archived

        // A later save of the same id carries stale presentation state
        // (autoPending/nil/nil): the conflict update must refresh title and
        // updated_at ONLY — title origin, archive and pin stay with their
        // dedicated setters (iOS writeConversation semantics).
        try await store.saveConversation(ConversationRecord(
            id: id, title: "Draft v2", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_060_000)))
        let retained = try await store.conversation(id: id)
        XCTAssertEqual(retained?.title, "Draft v2")
        XCTAssertEqual(retained?.titleOrigin, .manual)
        XCTAssertEqual(retained?.archivedAt, archivedAt)
        XCTAssertEqual(retained?.pinnedAt, pinnedAt)

        // Dedicated setters still own their columns.
        try await store.setArchived(id: id, archived: false)
        try await store.setPinned(id: id, pinnedAt: nil)
        let settled = try await store.conversation(id: id)
        XCTAssertEqual(settled?.archivedAt, nil)
        XCTAssertEqual(settled?.pinnedAt, nil)
        XCTAssertEqual(settled?.isVisibleInOrdinaryList, true)
    }

    // MARK: - 3. iOS visibility / editor-ownership metadata stays in the real
    //            table and out of the ordinary list

    func testVisibilityAndEditorOwnershipRoundTripThroughRealTable() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let store = SQLiteConversationStore(database: manager)

        let hiddenID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: hiddenID, title: "Authoring draft",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            titleOrigin: .manual, purpose: .ordinary, visibility: .skillAuthoring))
        let hidden = try await store.conversation(id: hiddenID)
        XCTAssertEqual(hidden?.visibility, .skillAuthoring)
        XCTAssertEqual(hidden?.isVisibleInOrdinaryList, false)
        XCTAssertFalse(try await store.conversations().contains { $0.id == hiddenID })

        // A skillAuthoring row cannot be pinned (iOS eligibility contract).
        do {
            try await store.setPinned(id: hiddenID, pinnedAt: Date())
            XCTFail("a skillAuthoring conversation must refuse pins")
        } catch {}

        let documentID = UUID()
        let ownedID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: ownedID, title: "Canvas assistant",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            titleOrigin: .manual, purpose: .ordinary,
            editorOwnership: .file(documentID)))
        let owned = try await store.conversation(id: ownedID)
        XCTAssertEqual(owned?.editorOwnership, .file(documentID))
        XCTAssertEqual(owned?.isVisibleInOrdinaryList, false)
        XCTAssertFalse(try await store.conversations().contains { $0.id == ownedID })
        let editorHits = try await store.editorConversations(
            kind: .file, containerID: documentID)
        XCTAssertEqual(editorHits.map(\.id), [ownedID])
        do {
            try await store.setPinned(id: ownedID, pinnedAt: Date())
            XCTFail("an editor-owned conversation must refuse pins")
        } catch {}

        // A verified-empty removal must refuse hidden / editor-owned rows.
        let blankHidden = UUID()
        try await store.saveConversation(ConversationRecord(
            id: blankHidden, title: "",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            titleOrigin: .autoPending, purpose: .ordinary, visibility: .skillAuthoring))
        XCTAssertEqual(try await store.deleteConversationIfVerifiedEmpty(id: blankHidden), false)
        XCTAssertNotNil(try await store.conversation(id: blankHidden))
    }

    // MARK: - 4. Pre-update Android fixture rows on the existing migration

    /// A database produced by the EXISTING Android migration chain, holding
    /// OLD-shape rows (raw physical storage, including a hand-carried iOS
    /// `interactive` part and its attachment linkage) must decode through the
    /// normal stores with NO migration and NO reset.
    func testPreUpdateAndroidFixtureRowsDecodeUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-compat-preupdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("floe.sqlite")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let manager = try DatabaseManager(path: databaseURL)
        do {
            try await manager.migrate()
            let conversationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            let messageID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
            let interactivePartID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
            let oldPartID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
            let attachmentID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

            // Lay down pre-update physical rows. The conversation row carries
            // only the v1 column set (title_origin/purpose/pinned_at take
            // their published defaults); the part rows include one
            // `interactive` row exactly as iOS persists it.
            try await manager.writer { db in
                try db.execute(
                    sql: """
                        INSERT INTO conversations (id, title, created_at, updated_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        conversationID.uuidString, "Legacy chat",
                        "2025-01-02T03:04:05.000Z", "2025-01-02T03:04:05.000Z",
                    ])
                try db.execute(
                    sql: """
                        INSERT INTO messages (id, conversation_id, role, content, created_at, run_id)
                        VALUES (?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        messageID.uuidString, conversationID.uuidString,
                        "assistant", "legacy content", "2025-01-02T03:04:06.000Z",
                    ])
                try db.execute(
                    sql: """
                        INSERT INTO attachments (
                            id, conversation_id, message_id, kind, display_name, uti,
                            byte_count, sha256, storage, url_bookmark, relative_path, created_at
                        ) VALUES (?, ?, ?, 'image', 'legacy.png', 'public.png', 10,
                                  'legacydigest', 'applicationSupport', NULL, 'attachments/legacy.png', ?)
                        """,
                    arguments: [
                        attachmentID.uuidString, conversationID.uuidString,
                        messageID.uuidString, "2025-01-02T03:04:07.000Z",
                    ])
                try db.execute(
                    sql: """
                        INSERT INTO message_parts (
                            id, message_id, part_index, kind, text, attachment_id,
                            metadata_json, created_at
                        ) VALUES (?, ?, 0, 'text', 'legacy content', NULL, '{}', ?)
                        """,
                    arguments: [oldPartID.uuidString, messageID.uuidString,
                                "2025-01-02T03:04:06.000Z"])
                try db.execute(
                    sql: """
                        INSERT INTO message_parts (
                            id, message_id, part_index, kind, text, attachment_id,
                            metadata_json, created_at
                        ) VALUES (?, ?, 1, 'interactive', '{"fallbackText":"legacy"}',
                                  NULL, '{"requestDigest":"legacydigest"}', ?)
                        """,
                    arguments: [interactivePartID.uuidString, messageID.uuidString,
                                "2025-01-02T03:04:06.100Z"])
            }

            let store = SQLiteConversationStore(database: manager)
            let message = try await store.message(id: messageID, conversationID: conversationID)
            let decoded = try XCTUnwrap(message)
            XCTAssertEqual(decoded.parts.map(\.partIndex), [0, 1])
            XCTAssertEqual(decoded.parts.map(\.kind.rawValue), ["text", "interactive"])
            XCTAssertEqual(decoded.parts[1].text, "{\"fallbackText\":\"legacy\"}")
            XCTAssertEqual(decoded.parts[1].metadata["requestDigest"], "legacydigest")
            XCTAssertEqual(decoded.content, "legacy content")

            let attachment = try await store.attachment(id: attachmentID)
            XCTAssertEqual(attachment?.relativePath, "attachments/legacy.png")
            XCTAssertEqual(attachment?.sha256, "legacydigest")

            let conversation = try await store.conversation(id: conversationID)
            XCTAssertEqual(conversation?.purpose, .ordinary)
            XCTAssertEqual(conversation?.titleOrigin, .autoPending)
            XCTAssertEqual(conversation?.isPinned, false)
        }
        do {
            try await manager.close()
        } catch {
            // The temp directory cleanup below still runs; a close failure
            // must not mask an assertion failure from the body.
        }
    }

    // MARK: - 5. Unknown kinds still fail closed

    func testUnknownPartKindStillFailsClosed() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let store = SQLiteConversationStore(database: manager)
        let conversationID = UUID()
        let messageID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()))
        try await store.appendMessage(PersistedMessage(
            id: messageID, conversationID: conversationID, role: "user",
            content: "x", createdAt: Date()))
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO message_parts (
                        id, message_id, part_index, kind, text, attachment_id,
                        metadata_json, created_at
                    ) VALUES (?, ?, 0, 'audio', NULL, NULL, '{}', ?)
                    """,
                arguments: [UUID().uuidString, messageID.uuidString, "2025-01-02T03:04:06.000Z"])
        }
        do {
            _ = try await store.parts(messageID: messageID)
            XCTFail("an unknown durable kind must not decode")
        } catch {
            // Expected: the store rejects rows outside the iOS kind set.
        }
    }

    // MARK: - 6. iOS confirmed-plan records stay immutable

    func testConfirmedPlanRecordCannotBeEdited() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let store = SQLiteConversationStore(database: manager)
        let conversationID = UUID()
        let messageID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()))
        let confirmed = PersistedMessage(
            id: messageID, conversationID: conversationID, role: "user",
            content: "confirmed plan text", createdAt: Date(),
            parts: [MessagePart(
                id: UUID(), messageID: messageID, partIndex: 0, kind: .text,
                text: "confirmed plan text",
                metadata: ["floe.plan.confirmation.v1": "1"])])
        try await store.appendMessage(confirmed)

        var edited = confirmed
        edited.content = "edited text"
        do {
            try await store.appendMessage(edited)
            XCTFail("a confirmed plan record must refuse edits")
        } catch {
            // Expected validation failure; the original row must be intact.
        }
        let readBack = try await store.message(id: messageID, conversationID: conversationID)
        XCTAssertEqual(readBack?.content, "confirmed plan text")
        XCTAssertEqual(readBack?.parts.first?.metadata["floe.plan.confirmation.v1"], "1")

        // The exact idempotent write is accepted and preserves the row.
        try await store.appendMessage(confirmed)
        let again = try await store.message(id: messageID, conversationID: conversationID)
        XCTAssertEqual(again?.content, "confirmed plan text")
    }

    // MARK: - 7. Existing migration chain still owns the contract

    func testExistingMigrationChainOwnsConversationContract() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let version = try await manager.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        let applied = try await manager.appliedMigrations()
        for identifier in ["v1", "v3", "v10", "v41_conversation_purpose",
                           "v50_conversation_pinning", "v55_conversation_continuity"] {
            XCTAssertTrue(applied.contains(identifier), "missing migration \(identifier)")
        }
        // The durable contract is TEXT-kind based: no CHECK constrains
        // message_parts.kind, which is exactly why the iOS `interactive`
        // kind needs no data migration.
        let partDDL = try await manager.reader { db in
            try String.fetchOne(db, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'message_parts'
                """)
        }
        let ddl = try XCTUnwrap(partDDL)
        XCTAssertFalse(ddl.contains("CHECK"), "message_parts must stay CHECK-free: \(ddl)")
        XCTAssertTrue(ddl.contains("kind TEXT NOT NULL"))
        XCTAssertTrue(ddl.contains("UNIQUE(message_id, part_index)"))

        // v55 preserved the iOS conversations metadata in the real table with
        // normal migration defaults (iOS v53/v61 DDL contract).
        let conversationDDL = try await manager.reader { db in
            try String.fetchOne(db, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'conversations'
                """)
        }
        let conversations = try XCTUnwrap(conversationDDL)
        XCTAssertTrue(conversations.contains("visibility TEXT NOT NULL DEFAULT 'normal'"))
        XCTAssertTrue(conversations.contains("'skillAuthoring'"))
        XCTAssertTrue(conversations.contains("editor_owner_kind TEXT"))
        XCTAssertTrue(conversations.contains("editor_container_id TEXT"))

        // ...and the columns read back with those defaults on a fresh row.
        let freshID = UUID()
        try await manager.writer { db in
            try db.execute(
                sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, '', ?, ?)",
                arguments: [freshID.uuidString, "2026-11-22T00:00:00.000Z", "2026-11-22T00:00:00.000Z"])
        }
        let store = SQLiteConversationStore(database: manager)
        let fresh = try await store.conversation(id: freshID)
        XCTAssertEqual(fresh?.visibility, .normal)
        XCTAssertEqual(fresh?.editorOwnership, nil)
        XCTAssertEqual(fresh?.isVisibleInOrdinaryList, true)
    }
}
