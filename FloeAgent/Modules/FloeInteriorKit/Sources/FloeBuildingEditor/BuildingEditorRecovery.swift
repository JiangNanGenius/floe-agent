// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeBuildingProject

public enum BuildingEditorOpenChoice: Equatable, Sendable {
    case published
    case workingCopy(String)
}

public struct BuildingEditorRecoveryCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let baseGenerationID: String?
    public let updatedAt: Date
    public let hasPendingSave: Bool
    public let isBasedOnCurrentGeneration: Bool
}

public struct BuildingEditorRecoveryOptions: Sendable {
    public let hasPublishedProject: Bool
    public let workingCopies: [BuildingEditorRecoveryCandidate]
}

extension BuildingEditorProjectSession {
    /// Inspect the repository before choosing a mount. Unfinished local work
    /// is listed, never silently selected, deleted or published by this query.
    public static func recoveryOptions(at directory: URL) async throws -> BuildingEditorRecoveryOptions {
        try await Task.detached {
            let repository=try BuildingProjectRepository.open(at:directory)
            _=try repository.recover(.reportOnly)
            let current=try repository.currentGeneration()
            let candidates=try repository.workingCopies().map { copy in
                BuildingEditorRecoveryCandidate(id:copy.workingCopyID,
                    baseGenerationID:copy.baseGenerationID,updatedAt:copy.metadata.updatedAt,
                    hasPendingSave:copy.metadata.pendingCommitID != nil,
                    isBasedOnCurrentGeneration:copy.baseGenerationID == current?.generationID)
            }.sorted{$0.updatedAt > $1.updatedAt}
            return BuildingEditorRecoveryOptions(hasPublishedProject:current != nil,workingCopies:candidates)
        }.value
    }
}
#endif
