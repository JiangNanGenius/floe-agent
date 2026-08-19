import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloePersistence
@testable import FloeModels

@Suite("FloeAgentRuntime.ConversationHistoryAssembler")
struct ConversationHistoryAssemblerTests {
    @Test("Five turns remain one ordered task context")
    func keepsFiveTurns() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Continuous", createdAt: Date(), updatedAt: Date()
        ))
        for turn in 1...5 {
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "user",
                content: "requirement-\(turn)", createdAt: Date().addingTimeInterval(Double(turn * 2))
            ))
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "assistant",
                content: "decision-\(turn)", createdAt: Date().addingTimeInterval(Double(turn * 2 + 1))
            ))
        }

        let history = try await ConversationHistoryAssembler(store: store).build(
            conversationID: conversationID
        )
        #expect(history.count == 10)
        #expect(history.first?.content == "requirement-1")
        #expect(history.last?.content == "decision-5")
    }

    @Test("Older turns become a bounded sourced summary")
    func summarizesOlderTurns() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        try await store.saveConversation(ConversationRecord(
            id: conversationID, title: "Compressed", createdAt: Date(), updatedAt: Date()
        ))
        for index in 0..<8 {
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "message-\(index)", createdAt: Date().addingTimeInterval(Double(index))
            ))
        }

        let history = try await ConversationHistoryAssembler(
            store: store, maximumMessages: 4
        ).build(conversationID: conversationID)
        #expect(history.count == 5)
        #expect(history[0].role == "system")
        #expect(history[0].content.contains("sourceMessageIDs="))
        #expect(history[0].content.contains("sourceDigest="))
        #expect(history[1].content == "message-4")
    }

    @Test("App-owned staged images are inlined after the picker scope closes")
    func inlinesApplicationSupportImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let bytes = Data("staged-image".utf8)
        try bytes.write(to: attachments.appendingPathComponent("picked.png"))
        let attachment = AttachmentRef(
            kind: .image,
            displayName: "picked.png",
            uti: "public.png",
            byteCount: bytes.count,
            storage: .applicationSupport,
            relativePath: "picked.png"
        )

        let images = ConversationHistoryAssembler.inlineImages(
            [attachment],
            applicationSupportRoot: root
        )

        #expect(images.count == 1)
        #expect(images[0].base64 == bytes.base64EncodedString())
        #expect(images[0].mimeType == "image/png")
    }

    @Test("A staged-image relative path cannot escape its app-owned directory")
    func rejectsApplicationSupportTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Attachments", isDirectory: true),
            withIntermediateDirectories: true
        )
        let outside = root.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let attachment = AttachmentRef(
            kind: .image,
            displayName: "outside.png",
            uti: "public.png",
            byteCount: 7,
            storage: .applicationSupport,
            relativePath: "../outside.png"
        )

        #expect(ConversationHistoryAssembler.inlineImages(
            [attachment],
            applicationSupportRoot: root
        ).isEmpty)
    }
}
