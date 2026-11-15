// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameGDevelopImportResult: Sendable {
    public let stored: GameStoredProject
    public let inspection: GameGDevelopInspection
    public let importedFileCount: Int
}

/// Thin integration with the existing content-addressed repository. The core
/// repository still owns identity, owner, expected revision, atomic import and
/// immutable history. This bridge only adds the GDevelop starter/inspection;
/// it never gates import on engine detection or rewrites imported bytes.
public enum GameGDevelopImportBridge {
    /// Import the complete tree (unknown files and nested projects included)
    /// through the core repository. Inspection is advisory and never gates it.
    public static func importTree(
        from source: URL,
        repository: FileGameProjectRepository,
        projectID: UUID,
        owner: GameProjectOwner,
        expectedRevision: String,
        replaceExisting: Bool = false
    ) async throws -> GameGDevelopImportResult {
        let inspection = try GameGDevelopInspector().inspect(rootURL: source)
        let stored = try await repository.importContents(
            from: source, into: projectID, owner: owner,
            expectedRevision: expectedRevision, replaceExisting: replaceExisting)
        return .init(stored: stored, inspection: inspection, importedFileCount: stored.files.count)
    }

    /// Create a real project identity first, then import the full starter tree
    /// into that same revision through `importContents`.
    public static func createProjectAndImportTemplate(
        repository: FileGameProjectRepository,
        projectID: UUID,
        owner: GameProjectOwner,
        title: String,
        projectUUID: UUID = UUID()
    ) async throws -> GameGDevelopImportResult {
        let created = try await repository.createProject(projectID: projectID, owner: owner,
                                                          title: title, engine: .gdevelop)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gdevelop-template-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GameGDevelopTemplate.makeProject(title: title, projectUUID: projectUUID)
        for (path, data) in files {
            let target = directory.appendingPathComponent(path.value)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: target, options: [.atomic])
        }
        let stored = try await repository.importContents(
            from: directory, into: projectID, owner: owner,
            expectedRevision: created.revision, replaceExisting: false)
        let inspection = try GameGDevelopInspector().inspect(rootURL: directory)
        return .init(stored: stored, inspection: inspection, importedFileCount: files.count)
    }
}
