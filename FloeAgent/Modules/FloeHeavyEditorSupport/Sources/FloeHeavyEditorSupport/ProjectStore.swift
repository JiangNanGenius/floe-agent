// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public actor HeavyEditorProjectStore {
    public let directory: URL
    private let expectedID: UUID
    private let kind: HeavyEditorKind
    public init(directory: URL, documentID: UUID, kind: HeavyEditorKind) throws {
        guard directory.isFileURL else { throw HeavyEditorError.invalidDocument }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.expectedID = documentID; self.kind = kind
    }
    public func create(_ document: HeavyEditorDocument) throws {
        try requireIdentity(document)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try locked {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw HeavyEditorError.revisionConflict }
            try write(document)
        }
    }
    public func read() throws -> HeavyEditorDocument { try locked { try readUnlocked() } }
    public func commit(content: EditorJSON, title: String? = nil, expectedRevision: UInt64) throws -> HeavyEditorDocument {
        try locked {
            var document = try readUnlocked()
            guard document.revision == expectedRevision, expectedRevision < UInt64.max else { throw HeavyEditorError.revisionConflict }
            document.content = content; document.revision += 1; document.modifiedAt = Date()
            if let title { document.title = title }
            try write(document); return document
        }
    }
    private var file: URL { directory.appendingPathComponent("Document.json") }
    private func requireIdentity(_ document: HeavyEditorDocument) throws {
        guard document.schemaVersion == 1, document.id == expectedID, document.kind == kind else { throw HeavyEditorError.wrongDocument }
    }
    private func readUnlocked() throws -> HeavyEditorDocument {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HeavyEditorError.invalidDocument }
        let document = try JSONDecoder().decode(HeavyEditorDocument.self, from: Data(contentsOf: file))
        try requireIdentity(document); return document
    }
    private func write(_ document: HeavyEditorDocument) throws {
        try requireIdentity(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        // A successful write includes a read-back of the exact revision and data.
        guard try readUnlocked() == document else { throw HeavyEditorError.invalidDocument }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent(".document.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HeavyEditorError.unavailable }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw HeavyEditorError.unavailable }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
