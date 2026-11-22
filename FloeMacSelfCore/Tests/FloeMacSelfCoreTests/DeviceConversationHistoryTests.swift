// SPDX-License-Identifier: MPL-2.0

import FloeModels
import FloePersistence
import Foundation
import Testing

@Test
func deviceHistoryImportsBothDirectionsAndKeepsTheNativeConversationIdentity() async throws {
    let first = try DatabaseManager.inMemory()
    let second = try DatabaseManager.inMemory()
    try await first.migrate()
    try await second.migrate()
    let left = SQLiteConversationStore(database: first)
    let right = SQLiteConversationStore(database: second)
    let task = UUID()
    let message = UUID()
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let part = MessagePart(messageID: message, partIndex: 0, kind: .text, text: "**One**",
                           metadata: ["local-bookmark": "discard"], createdAt: created)
    try await left.saveConversationWithCanonicalWorkspace(.init(id: task, title: "Fixture", createdAt: created, updatedAt: created))
    try await left.appendMessage(.init(id: message, conversationID: task, role: "user", content: "One",
                                        createdAt: created, parts: [part]))
    try await left.appendMessage(.init(id: UUID(), conversationID: task, role: "system", content: "Local system input",
                                        createdAt: created))
    let outgoing = try await left.deviceHistory(conversationID: task)
    let received = try DeviceConversationHistory(data: outgoing.encoded())
    let receipt = try await right.importDeviceHistory(received)
    #expect(receipt.conversationID == task && receipt.createdConversation && receipt.addedMessages == 1)
    let messages = try await right.messages(conversationID: task)
    #expect(messages.map(\.id) == [message])
    #expect(messages.first?.createdAt == created)
    #expect(messages.first?.parts.first?.id == part.id)
    #expect(messages.first?.parts.first?.text == "**One**")
    #expect(messages.first?.parts.first?.metadata.isEmpty == true)
    #expect(try await SQLiteWorkspaceStore(database: second).workspaceID(conversationID: task) != nil)
    #expect(try await right.importDeviceHistory(received).addedMessages == 0)

    let reply = UUID()
    try await right.appendMessage(.init(id: reply, conversationID: task, role: "assistant", content: "Two",
                                        createdAt: created.addingTimeInterval(1)))
    let returned = try await right.deviceHistory(conversationID: task)
    #expect(try await left.importDeviceHistory(returned).addedMessages == 1)
    #expect(try await left.message(id: reply, conversationID: task)?.content == "Two")
    #expect(try await left.message(id: message, conversationID: task)?.parts.first?.metadata == part.metadata)

    let earlier = UUID()
    try await right.appendMessage(.init(id: earlier, conversationID: task, role: "user", content: "Earlier",
                                        createdAt: created.addingTimeInterval(-1)))
    try await right.appendMessage(.init(id: reply, conversationID: task, role: "assistant", content: "Edited remotely",
                                        createdAt: created.addingTimeInterval(1)))
    let conflicting = try await right.deviceHistory(conversationID: task)
    await #expect(throws: DeviceConversationHistoryError.messageConflict(reply)) {
        try await left.importDeviceHistory(conflicting)
    }
    #expect(try await left.message(id: earlier, conversationID: task) == nil)
    #expect(try await left.message(id: reply, conversationID: task)?.content == "Two")
    #expect(try await right.message(id: reply, conversationID: task)?.content == "Edited remotely")
}
