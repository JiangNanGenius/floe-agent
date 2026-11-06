// SPDX-License-Identifier: MPL-2.0
import Foundation
@testable import FloeMeetings

enum TestServices {
    /// Fresh service over a unique temp database path.
    static func makeService() throws -> (MeetingService, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-meetings-tests-\(UUID().uuidString).sqlite")
        let database = try MeetingDatabase(path: url.path)
        return (MeetingService(database: database), url)
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    /// Register an owned file session before injecting recognizer results.
    static func importedSession(_ service: MeetingService, meeting: MeetingID) async throws -> CaptureSessionID {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("meeting-fixture-\(UUID()).wav")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await service.importFile(meeting: meeting, file: file, kind: .importedAudio) { _ in
            try MediaTimeRange(start: 0, end: 600)
        }
    }
}
