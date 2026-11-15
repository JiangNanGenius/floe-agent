// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameAuthoring
import FloeGameWebKit

/// The real AI editing service receives a context over the same owned live
/// root as the IDE and native controls. No revision materialization is opened.
public actor ExistingWorkspaceGameContexts: GameAuthoringContextHost, GameRunContextHost {
    private let repository: FileGameProjectRepository
    private let targets: [UUID: ExistingGameWorkspaceTarget]
    public init(repository: FileGameProjectRepository, targets: [ExistingGameWorkspaceTarget]) throws {
        guard Set(targets.map { $0.binding.projectID }).count == targets.count else {
            throw GameProjectError.invalidContext
        }
        self.repository = repository
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.binding.projectID, $0) })
    }
    public func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext {
        guard let target = targets[captured.projectID], target.binding.owner == captured.owner,
              target.binding.rootURL == captured.rootURL,
              target.binding.environmentID == captured.environmentID else { throw GameProjectError.invalidContext }
        let checkpoint = try target.revisions.checkpoint()
        let opened = try await repository.openWorkingProject(captured.projectID, owner: captured.owner)
        try target.revisions.validate(checkpoint)
        guard opened.binding == target.binding else { throw GameProjectError.invalidContext }
        let project = opened.project
        return try GameProjectContext(projectID: project.projectID, owner: project.owner,
            rootURL: target.binding.rootURL, savedRevision: project.revision,
            environmentID: target.binding.environmentID)
    }
}
