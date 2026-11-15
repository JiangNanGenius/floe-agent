// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameAuthoring
import FloeGameCore
import FloeGameWebKit

enum GameProjectSelectionValidation {
    static func mapProject(_ error: GameProjectError) -> GameProjectFlowError {
        switch error {
        case .contextChanged(let change):
            return .staleContext(change)
        case .ownershipMismatch:
            return .wrongOwner
        case .projectNotFound:
            return .project(error)
        case .importDestinationNotEmpty:
            return .nonEmptyProject
        case .conflict(let expected, let actual):
            return .staleProject(expected: expected, actual: actual)
        default:
            return .project(error)
        }
    }

    static func project(_ project: GameStoredProject,
                        context: GameProjectContext) throws {
        guard project.projectID == context.projectID else {
            throw GameProjectFlowError.invalidContext
        }
        guard project.owner == context.owner else {
            throw GameProjectFlowError.wrongOwner
        }
        guard project.revision == context.savedRevision else {
            throw GameProjectFlowError.staleProject(
                expected: context.savedRevision, actual: project.revision)
        }
    }

    /// The repository is authoritative for the saved revision. Comparing the
    /// reopened HEAD fences a project object captured before a save/import.
    static func currentProject(_ project: GameStoredProject,
                               repository: FileGameProjectRepository) async throws {
        let current: GameStoredProject
        do {
            current = try await repository.open(project.projectID, owner: project.owner)
        } catch let error as GameProjectError {
            throw mapProject(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
        guard current.revision == project.revision else {
            throw GameProjectFlowError.staleProject(
                expected: project.revision, actual: current.revision)
        }
    }

    /// The host's existing context service is authoritative for access,
    /// environment and the saved revision.
    static func currentContext(
        _ context: GameProjectContext,
        contexts: any GameAuthoringContextHost & GameRunContextHost
    ) async throws {
        let current: GameProjectContext
        do {
            current = try await contexts.currentContext(for: context)
        } catch let error as GameProjectError {
            throw GameProjectFlowError.project(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
        do {
            try context.validate(current: current)
        } catch let error as GameProjectError {
            if case .contextChanged(let change) = error {
                throw GameProjectFlowError.staleContext(change)
            }
            throw GameProjectFlowError.project(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
    }

    /// A new starter/import revision must stay on the same owner, environment
    /// and live root. A different root is another project, never a hidden sync.
    static func handoff(_ revised: GameProjectContext,
                        previous: GameProjectContext,
                        project: GameStoredProject) throws {
        guard revised.projectID == project.projectID,
              revised.projectID == previous.projectID,
              revised.owner == previous.owner,
              revised.environmentID == previous.environmentID,
              revised.rootURL == previous.rootURL,
              revised.savedRevision == project.revision else {
            throw GameProjectFlowError.contextHandoff(
                "The host returned a different project/owner/environment/root/revision.")
        }
    }
}
