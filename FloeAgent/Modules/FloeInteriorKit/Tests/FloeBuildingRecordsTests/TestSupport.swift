import Foundation
import XCTest
@testable import FloeBuildingRecords

final class TestProject {
    let root: URL
    let store: ProjectRecordsStore

    init(name: String = "Test Project", limits: RecordsLimits = RecordsLimits()) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBuildingRecordsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        do {
            self.store = try ProjectRecordsStore.createProject(at: root, name: name, limits: limits)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() {
        try? store.close()
        try? FileManager.default.removeItem(at: root)
    }

    deinit {
        cleanup()
    }
}

func csvData(_ text: String) -> Data {
    Data(text.utf8)
}

func assertRecordsError(
    _ expression: @autoclosure () throws -> Any,
    _ expected: BuildingRecordsError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(error as? BuildingRecordsError, expected, file: file, line: line)
    }
}

func createRoom(
    _ store: ProjectRecordsStore,
    name: String,
    storey: String? = nil,
    kind: RoomKind = .other,
    aliases: [String] = [],
    revision: Int
) throws -> ProjectMutation<RoomRecord> {
    try store.createRoom(
        RoomDraft(name: name, storey: storey, kind: kind, aliases: aliases),
        expectedRevision: revision
    )
}

func importTextSource(
    _ store: ProjectRecordsStore,
    kind: SourceKind = .note,
    title: String = "Note",
    name: String = "note.txt",
    mediaType: String = "text/plain",
    text: String,
    roomIDs: [RoomID] = [],
    idempotencyKey: String? = nil,
    revision: Int
) throws -> ProjectMutation<SourceImportResult> {
    try store.importSource(
        SourceImportRequest(
            kind: kind,
            title: title,
            originalName: name,
            mediaType: mediaType,
            data: Data(text.utf8),
            roomIDs: roomIDs,
            idempotencyKey: idempotencyKey
        ),
        expectedRevision: revision
    )
}
