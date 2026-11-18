// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGameCore

/// The library resolves the containing directory and record first. This small
/// manifest verifies identity; it never selects a workspace or execution owner.
struct SpaceGameOriginal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let projectID: UUID

    struct Location: Sendable {
        let files: URL
        let history: URL
        let support: URL
        let importJobs: URL
        let originalArchives: URL
        let transferJobs: URL
    }

    static func location(directory: URL) -> Location {
        let game = directory.appendingPathComponent("Game", isDirectory: true)
        let support = game.appendingPathComponent("Support", isDirectory: true)
        return .init(files: game.appendingPathComponent("Files", isDirectory: true),
            history: game.appendingPathComponent("History", isDirectory: true), support: support,
            importJobs: support.appendingPathComponent("ImportJobs", isDirectory: true),
            originalArchives: support.appendingPathComponent("OriginalArchives", isDirectory: true),
            transferJobs: support.appendingPathComponent("TransferJobs", isDirectory: true))
    }

    /// Called inside PersonalContentLibrary.create's unpublished staging area.
    /// No template is seeded: importing an external project remains the next step.
    static func create(id: UUID, title: String, directory: URL) async throws {
        let paths = location(directory: directory)
        for url in [paths.files, paths.history, paths.support, paths.importJobs, paths.originalArchives, paths.transferJobs] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let repository = try FileGameProjectRepository(directory: paths.history)
        _ = try await repository.createProject(projectID: id, owner: .space(recordID: id), title: title)
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Self(schemaVersion: 1, projectID: id))
        try data.write(to: directory.appendingPathComponent("Game/Original.json"), options: [.atomic])
    }

    static func read(id: UUID, directory: URL) async throws -> (paths: Location, project: GameStoredProject) {
        let reader = try GameProjectReader(rootURL: directory, maximumFileBytes: 8_192)
        guard let data = try reader.read(GameRelativePath("Game/Original.json")) else { throw PersonalContentError.invalidProject }
        let original = try JSONDecoder().decode(Self.self, from: data)
        guard original.schemaVersion == 1, original.projectID == id else { throw PersonalContentError.invalidProject }
        let paths = location(directory: directory)
        for url in [paths.files, paths.history, paths.support] {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PersonalContentError.invalidProject }
        }
        let repository = try FileGameProjectRepository(directory: paths.history)
        let project = try await repository.open(id, owner: .space(recordID: id))
        guard project.projectID == id, project.owner == .space(recordID: id) else { throw PersonalContentError.invalidProject }
        return (paths, project)
    }
}
#endif
