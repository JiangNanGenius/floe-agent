// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// The last explicit Save-to-Space destination, as routing metadata only.
/// It carries no path, environment or permission. The host resolves both
/// projects again and validates revisions before preparing a copy.
public struct GameSaveDestinationLink: Equatable, Sendable {
    public let destinationProjectID: UUID
    public let lastSourceRevision: String
    public let lastDestinationRevision: String
    public let sourceEngine: GameEngineID?
    public let destinationEngine: GameEngineID?

    public init(destinationProjectID: UUID, lastSourceRevision: String,
                lastDestinationRevision: String, sourceEngine: GameEngineID?,
                destinationEngine: GameEngineID?) {
        self.destinationProjectID = destinationProjectID
        self.lastSourceRevision = lastSourceRevision
        self.lastDestinationRevision = lastDestinationRevision
        self.sourceEngine = sourceEngine
        self.destinationEngine = destinationEngine
    }
}

/// A user-visible choice. The policy never decides to merge or silently
/// synchronize two independently edited projects.
public enum GameSaveChoice: String, CaseIterable, Equatable, Sendable {
    case updateExistingCopy
    case saveAsNewProject

    public var titleZH: String {
        switch self {
        case .updateExistingCopy: "更新已有副本"
        case .saveAsNewProject: "另存为新项目"
        }
    }
    public var titleEN: String {
        switch self {
        case .updateExistingCopy: "Update existing copy"
        case .saveAsNewProject: "Save as new project"
        }
    }
}

public enum GameSaveDecision: Equatable, Sendable {
    /// Source and destination still match the last explicit link; no write.
    case upToDate
    /// No destination yet, or the last copy was deleted/moved. The host first
    /// creates a new owned empty Space project.
    case createNewCopy
    /// Only the source changed since the link and the destination is unchanged.
    case updateExistingCopy
    /// Both sides changed, or the link cannot prove the destination. The user
    /// must choose explicitly; never hidden synchronization.
    case requiresChoice([GameSaveChoice])
    /// The destination is inaccessible/changed owner. The host can still
    /// create a new copy; it must not overwrite that destination.
    case requiresNewCopy(reason: String)

    public var choices: [GameSaveChoice] {
        if case .requiresChoice(let values) = self { return values }
        return []
    }
}

/// Pure policy for explicit chat→Space and Space→chat copies. The destination
/// must have been created as an independent empty project first; this policy
/// never describes a shared working tree or a hidden sync.
public enum GameSaveDestinationPolicy {
    public static func decide(sourceRevision: String,
                              sourceEngine: GameEngineID?,
                              destination: GameStoredProject?,
                              link: GameSaveDestinationLink?) -> GameSaveDecision {
        guard let destination else {
            return link == nil ? .createNewCopy : .requiresNewCopy(reason: "The last destination is unavailable.")
        }
        guard destination.owner.isSpaceProject else {
            return .requiresNewCopy(reason: "The destination is not an independently owned Space project.")
        }
        if let link, link.destinationProjectID != destination.projectID {
            return .requiresNewCopy(reason: "The last destination binding no longer matches the selected project.")
        }
        if let link, let sourceEngine, let destinationEngine = destination.engine,
           sourceEngine != destinationEngine {
            // Engine conversion is a new project/conversion copy; never an
            // in-place overwrite of an independently edited project.
            return .requiresNewCopy(reason: "Changing the engine creates a new conversion project.")
        }
        guard let link, destination.projectID == link.destinationProjectID else {
            return .createNewCopy
        }
        let sourceUnchanged = link.lastSourceRevision == sourceRevision
        let destinationUnchanged = link.lastDestinationRevision == destination.revision
        if sourceUnchanged && destinationUnchanged { return .upToDate }
        if !sourceUnchanged && destinationUnchanged {
            return .updateExistingCopy
        }
        if sourceUnchanged && !destinationUnchanged {
            // The destination has newer edits. Re-saving the same source would
            // overwrite them, so this is an explicit user decision too.
            return .requiresChoice([.updateExistingCopy, .saveAsNewProject])
        }
        return .requiresChoice([.updateExistingCopy, .saveAsNewProject])
    }

    /// A save that completed must be reported even when updating the optional
    /// default link loses a concurrent preference race. This method only says
    /// whether the new preference may be stored; it never undoes a copy.
    public static func mayReplaceLink(current: GameSaveDestinationLink?,
                                      expected: GameSaveDestinationLink?) -> Bool {
        current == expected
    }
}

extension GameProjectOwner {
    var isSpaceProject: Bool {
        if case .space = self { return true }
        return false
    }
}

public enum GameSaveDestinationError: Error, Equatable, LocalizedError {
    case explicitChoiceRequired([GameSaveChoice])
    case destinationChanged
    case engineChangeRequiresNewProject

    public var errorDescription: String? {
        switch self {
        case .explicitChoiceRequired(let choices):
            return "Choose how to save: " + choices.map(\.titleEN).joined(separator: " or ") + "."
        case .destinationChanged:
            return "The destination project changed. Review the updated files or save as a new project."
        case .engineChangeRequiresNewProject:
            return "Changing the engine creates a new project; the existing copy is unchanged."
        }
    }
}
