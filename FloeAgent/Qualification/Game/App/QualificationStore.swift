// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit
import FloeGameAuthoring

/// Qualification-only implementation of the App's authoritative context ports.
/// Each saved revision gets a verified, immutable materialization for play.
actor QualificationStore: GameRunContextHost, GameAuthoringContextHost {
    let repository: FileGameProjectRepository
    let directory: URL
    var active: UUID?
    init(directory: URL) throws {
        self.directory = directory
        repository = try .init(directory: directory.appendingPathComponent("Repository"))
    }
    func activate(_ id: UUID) { active = id }
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext {
        guard active == captured.projectID else { throw GameProjectError.contextChanged(.project) }
        return try await context(id: captured.projectID, owner: captured.owner)
    }
    func context(id: UUID, owner: GameProjectOwner) async throws -> GameProjectContext {
        guard active == id else { throw GameProjectError.contextChanged(.project) }
        let project = try await repository.open(id, owner: owner)
        let target = directory.appendingPathComponent("Materializations/" + id.uuidString + "/" + project.revision)
        if !FileManager.default.fileExists(atPath: target.path) {
            _ = try await repository.export(id, owner: owner, expectedRevision: project.revision, to: target)
        }
        return try .init(projectID: id, owner: owner, rootURL: target, savedRevision: project.revision)
    }
    func contextAfterCommit(_ project: GameStoredProject, previous: GameProjectContext) async throws -> GameProjectContext {
        guard active == previous.projectID, project.projectID == previous.projectID, project.owner == previous.owner else { throw GameProjectError.invalidContext }
        return try await context(id: project.projectID, owner: project.owner)
    }
}

/// Deterministic contract fixture, NOT an inference or model-account test.
struct QualificationEditProvider: GameAIEditProvider {
    func propose(_ request: GameAIEditRequest) async throws -> GameAIEditProposal {
        let path = try GameRelativePath("game-config.json")
        guard let bytes = request.files[path] else { throw GameProjectError.invalidEdit }
        let changed = try GameJSONPatch.replacing(bytes, at: [.key("speed")], with: Data("240".utf8))
        return try .init(baseRevision: request.context.savedRevision, changes: [.write(path, changed)], summary: "Deterministic qualification: set speed to 240")
    }
}
