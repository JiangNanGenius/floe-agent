// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeMeetings
@testable import FloeApp

@Suite("Personal meeting storage")
struct NativeMeetingIntegrationTests {
    @Test func createdMeetingSurvivesTheStagingMoveAndReopensInTheNativeService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = PersonalContentService(root: root)
        let record = try await content.create(kind: .meeting, title: "Meeting original")
        let library = try await content.library()
        let location = try await library.resolve(record.id)
        let database = try MeetingDatabase(path: location.url.appendingPathComponent("Meeting/meeting.sqlite").path)
        let service = MeetingService(database: database)
        let meeting = try await service.meeting(MeetingID(record.id))
        #expect(meeting.title == record.title)
        _ = try await service.addNote(meeting: meeting.id, body: "Original manual note")
        let todo = try await service.addTodo(meeting: meeting.id, text: "Review source", origin: .user)
        _ = try await service.updateTodo(todo.id, meeting: meeting.id, status: .done)
        let another = MeetingService(database: try MeetingDatabase(path: location.url.appendingPathComponent("Meeting/meeting.sqlite").path))
        #expect(try await another.notes(meeting: meeting.id).map(\.body) == ["Original manual note"])
        #expect(try await another.todos(meeting: meeting.id).first?.status == .done)
        #expect(try await another.meeting(meeting.id).id.rawValue == record.id)
    }
}
#endif
