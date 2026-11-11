// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("Saved inline-content ownership and retrieval", .serialized)
@MainActor
struct ChatInlineContentContractTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InlineContent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func artifact(runID: UUID, bytes: Data) -> ToolArtifactReference {
        let id = UUID()
        return .init(id: id, relativePath: "PresentationArtifacts/\(runID.uuidString)/\(id.uuidString).chart.json",
            mimeType: "application/vnd.floe.chart+json", byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes))
    }
    private func eventPayload(_ artifact: ToolArtifactReference, tool: String = "document.presentation.createInline",
                              status: String = "ok") throws -> String {
        // Field ordering is deliberately irrelevant: native event payloads
        // are decoded by key, never by searching for substrings in summaries.
        let fields = ["tool": tool, "artifactRefsJSON": String(decoding: try JSONEncoder().encode([artifact]), as: UTF8.self),
                      "id": "chart-call", "summary": "old chart created", "status": status]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: []), as: UTF8.self)
    }
    @Test func legacyArtifactResolvesAtTheSamePositionAfterStoreReopen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("chat.sqlite")
        let database = try DatabaseManager(path: databaseURL); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic inline test", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Chart", startedAt: Date(), endedAt: Date()))
        let bytes = Data("{\"type\":\"line\",\"series\":[{\"name\":\"A\",\"points\":[{\"label\":\"one\",\"value\":1}]}]}".utf8)
        let ref = artifact(runID: run, bytes: bytes)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: eventPayload(ref))
        let file = root.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        let answer = "Before\n\n" + uri.markdown(title: "Chart") + "\n\nAfter"
        let message = UUID()
        try await conversations.appendMessage(.init(id: message, conversationID: task, role: "assistant", content: answer, createdAt: Date(), runID: run))
        // A different database manager and fresh services read durable bytes;
        // no view cache or process-global reference map participates.
        let reopened = try DatabaseManager(path: databaseURL)
        let restoredConversations = SQLiteConversationStore(database: reopened), restoredRuns = SQLiteRunStore(database: reopened)
        let resolved = try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: false),
            conversations: restoredConversations, runs: restoredRuns)
        #expect(resolved == .artifact(ref, runID: run, tool: "document.presentation.createInline"))
        #expect(try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root).data == bytes)
        #expect(try await restoredConversations.messages(conversationID: task).first?.content == answer)
    }
    @Test func anotherTaskAndTemporaryChatCannotAdoptTheSameReceipt() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), other = UUID(), run = UUID()
        for id in [task, other] { try await conversations.saveConversation(.init(id: id, title: "Synthetic owner", createdAt: Date(), updatedAt: Date())) }
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Chart", startedAt: Date()))
        let ref = artifact(runID: run, bytes: Data("{}".utf8))
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: eventPayload(ref))
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        for scope in [ChatInlineContentScope(conversationID: other, isTemporary: false), .init(conversationID: task, isTemporary: true)] {
            await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
                try await ChatInlineContentResolver.resolve(uri, scope: scope, conversations: conversations, runs: runs)
            }
        }
    }
    @Test func missingFailedAndExternalReceiptsNeverResolve() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic missing", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Chart", startedAt: Date()))
        for tool in ["mcp.untrusted.chart", "document.presentation.createInline"] {
            let ref = artifact(runID: run, bytes: Data("{}".utf8))
            _ = try await runs.appendEvent(runID: run, kind: .toolResult,
                payloadJSON: eventPayload(ref, tool: tool, status: tool.hasPrefix("mcp.") ? "ok" : "failed"))
            let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
            await #expect(throws: ChatInlineContentResolutionError.unavailable) {
                try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
            }
        }
    }
    @Test func byteTamperingMissingFilesAndInRootSymlinksAreRejected() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), bytes = Data("correct".utf8), ref = artifact(runID: run, bytes: bytes)
        let file = root.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        #expect(try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root).data == bytes)
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root) }
        let real = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try bytes.write(to: real.appendingPathComponent(file.lastPathComponent))
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: real)
        #expect(throws: (any Error).self) { try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "document.presentation.createInline", root: root) }
    }
    @Test func outputReceiptsKeepRealTaskCallAndIdentitySeals() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), bytes = Data("synthetic file output".utf8)
        try bytes.write(to: source)
        let run = UUID(), task = UUID(), context = ToolContext(runID: run, toolCallID: "audio-call", cancellation: CancellationToken(), conversationID: task)
        let receipt = try RunOutputSnapshotStore.publish(.init(producerTool: "studio.run", slot: "audio",
            commit: .init(sourceURL: source, sha256: FloeDigest.sha256Hex(bytes), byteCount: bytes.count,
                displayName: "output.wav", mimeType: "audio/wav")), using: context, artifactRoot: root.appendingPathComponent("store"))
        #expect(ChatInlineContentCatalog.accepts(receipt, runID: run, taskID: task, callID: "audio-call", tool: "studio.run"))
        #expect(!ChatInlineContentCatalog.accepts(receipt, runID: run, taskID: UUID(), callID: "audio-call", tool: "studio.run"))
        #expect(!ChatInlineContentCatalog.accepts(receipt, runID: run, taskID: task, callID: "other-call", tool: "studio.run"))
        var changed = receipt; changed.outputID = String(repeating: "a", count: 64)
        #expect(!ChatInlineContentCatalog.accepts(changed, runID: run, taskID: task, callID: "audio-call", tool: "studio.run"))
    }
    @Test func attachmentsRequireTheActualMessagePartEvenForLegacyMetadata() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), owner = UUID(), otherMessage = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Synthetic attachment", createdAt: Date(), updatedAt: Date()))
        for id in [owner, otherMessage] {
            try await conversations.appendMessage(.init(id: id, conversationID: task, role: "assistant", content: "Files", createdAt: Date()))
        }
        let attachment = AttachmentRef(conversationID: task, kind: .document, displayName: "result.pdf",
            uti: "com.adobe.pdf", byteCount: 3, sha256: FloeDigest.sha256Hex(Data("pdf".utf8)),
            // Stored dates have millisecond precision. Keep the fixture exact
            // so this full-record comparison tests ownership, not clock rounding.
            storage: .applicationSupport, relativePath: "synthetic.pdf", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await conversations.saveAttachment(attachment)
        try await conversations.appendMessage(.init(id: owner, conversationID: task, role: "assistant", content: "Files", createdAt: Date(),
            parts: [.init(messageID: owner, partIndex: 0, kind: .file, text: attachment.displayName, attachmentID: attachment.id)]))
        let valid = try #require(ChatContentReference(kind: .attachment, ownerID: owner, contentID: attachment.id.uuidString))
        #expect(try await ChatInlineContentResolver.resolve(valid, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
            == .attachment(attachment, messageID: owner))
        let wrong = try #require(ChatContentReference(kind: .attachment, ownerID: otherMessage, contentID: attachment.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(wrong, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
    }

    #if canImport(AlarmKit)
    // MARK: - Native timer binding receipts (forged producer / foreign owner / missing receipt / reopen)

    private func timerArtifact(runID: UUID) -> ToolArtifactReference {
        let id = UUID()
        let bytes = Data("{\"version\":1}".utf8)
        return .init(id: id,
            relativePath: "TimerArtifacts/\(runID.uuidString)/\(id.uuidString).timer.json",
            mimeType: "application/vnd.floe.native-timer+json",
            byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes))
    }

    private func timerEventPayload(_ artifact: ToolArtifactReference, tool: String = "apple.alarm.schedule",
                                   status: String = "ok") throws -> String {
        let fields = ["tool": tool, "artifactRefsJSON": String(decoding: try JSONEncoder().encode([artifact]), as: UTF8.self),
                      "id": "timer-call", "summary": "timer scheduled", "status": status]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: []), as: UTF8.self)
    }

    @Test func timerBindingResolvesAndSurvivesStoreReopen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("timer-chat.sqlite")
        let database = try DatabaseManager(path: databaseURL); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Timer", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Tea", startedAt: Date(), endedAt: Date()))
        let ref = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(ref))
        let file = root.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":1}".utf8).write(to: file)

        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        let reopened = try DatabaseManager(path: databaseURL)
        let resolved = try await ChatInlineContentResolver.resolve(uri,
            scope: .init(conversationID: task, isTemporary: false),
            conversations: SQLiteConversationStore(database: reopened), runs: SQLiteRunStore(database: reopened))
        #expect(resolved == .artifact(ref, runID: run, tool: "apple.alarm.schedule"))
        let loaded = try VerifiedChatInlineArtifact.load(ref, runID: run, tool: "apple.alarm.schedule", root: root)
        #expect(loaded.data == Data("{\"version\":1}".utf8))
    }

    @Test func forgedTimerProducerNeverResolves() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Forged", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "T", startedAt: Date()))
        // Same path/mime bytes, but the receipt claims an untrusted producer.
        let ref = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(ref, tool: "mcp.untrusted.timer"))
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
        // Wrong path shape (directory spoof) is rejected by the catalog itself.
        #expect(!ChatInlineContentCatalog.accepts(.init(id: ref.id,
            relativePath: "OtherArtifacts/\(run.uuidString)/\(ref.id.uuidString).timer.json",
            mimeType: ref.mimeType, byteCount: ref.byteCount, sha256: ref.sha256), runID: run, tool: "apple.alarm.schedule"))
        #expect(!ChatInlineContentCatalog.accepts(.init(id: ref.id,
            relativePath: "TimerArtifacts/\(run.uuidString)/\(ref.id.uuidString).timer.json",
            mimeType: "text/plain", byteCount: ref.byteCount, sha256: ref.sha256), runID: run, tool: "apple.alarm.schedule"))
    }

    @Test func foreignConversationCannotAdoptATimerReceipt() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), other = UUID(), run = UUID()
        for id in [task, other] { try await conversations.saveConversation(.init(id: id, title: "Owner", createdAt: Date(), updatedAt: Date())) }
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "T", startedAt: Date()))
        let ref = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(ref))
        let uri = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: ref.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
            try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: other, isTemporary: false), conversations: conversations, runs: runs)
        }
        await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
            try await ChatInlineContentResolver.resolve(uri, scope: .init(conversationID: task, isTemporary: true), conversations: conversations, runs: runs)
        }
    }

    @Test func missingOrFailedTimerReceiptNeverResolves() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Missing", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "T", startedAt: Date()))
        // Receipt exists on disk bytes shape but no toolResult event at all.
        let orphan = timerArtifact(runID: run)
        let orphanURI = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: orphan.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(orphanURI, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
        // Failed schedule receipt is equally unusable.
        let failed = timerArtifact(runID: run)
        _ = try await runs.appendEvent(runID: run, kind: .toolResult, payloadJSON: timerEventPayload(failed, status: "failed"))
        let failedURI = try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: failed.id.uuidString))
        await #expect(throws: ChatInlineContentResolutionError.unavailable) {
            try await ChatInlineContentResolver.resolve(failedURI, scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
        }
    }
    #endif
}
#endif
