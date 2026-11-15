// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGameCore
import FloeGameBuildKit

/// Creates the owned, empty game project BEFORE any template/import. It mirrors
/// Root's verified `SpaceGameOriginal` layout but can record the engine selected
/// at creation time (including a conversion destination's target engine).
/// Unknown files are never seeded here.
enum GameProjectLibraryRecord {
    static func create(id: UUID, title: String, engine: GameEngineID?,
                       directory: URL) async throws {
        let paths = SpaceGameOriginal.location(directory: directory)
        for url in [paths.files, paths.history, paths.support, paths.importJobs,
                    paths.originalArchives, paths.transferJobs] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let repository = try FileGameProjectRepository(directory: paths.history)
        _ = try await repository.createProject(projectID: id, owner: .space(recordID: id),
            title: title, engine: engine)
        try Task.checkCancellation()
        let original = SpaceGameOriginal(schemaVersion: 1, projectID: id)
        try JSONEncoder().encode(original).write(
            to: directory.appendingPathComponent("Game/Original.json"), options: [.atomic])
    }
}

extension PersonalContentService {
    /// Explicit new-game flow used by the Space library and the game AI tool.
    /// The library's unpublished staging area receives the first empty
    /// repository revision; import/starter seeding happens afterward.
    func createGame(title: String, engine: GameEngineID? = nil,
                    folders: [String] = [], id: UUID = UUID()) async throws -> PersonalContentRecord {
        let library = try library()
        let record = try await library.create(kind: .game, title: title, in: folders, id: id) {
            directory, projectID in
            try await GameProjectLibraryRecord.create(id: projectID, title: title,
                engine: engine, directory: directory)
        }
        try await verify(record)
        return record
    }
}
#endif
