// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The agreed engine scope, not a list of installed or executable adapters.
public enum GameEngineID: String, CaseIterable, Codable, Hashable, Sendable {
    case rpgMakerXP, rpgMakerVX, rpgMakerVXAce, rpgMakerMV, rpgMakerMZ
    case phaser, kaplay, godot, babylon, playcanvas, love, renpy, tic80
    case ink, twine, gdevelop, cocosCreator, microStudio, wasm4, unity
}

public enum GameProjectError: Error, Equatable, Sendable {
    case invalidRelativePath
    case invalidContext
    case rootUnavailable
    case unreadableFile(String)
    case unsafePath(String)
    case limitExceeded(String)
    case invalidManifest(String)
    case engineNotDetected(GameEngineID)
    case duplicateAdapter(GameEngineID)
    case unsupportedRoute(GameEngineID)
    case invalidArtifact
    case contextChanged(GameContextChange)
    case io(String)
    case projectNotFound(UUID)
    case ownershipMismatch
    case conflict(expected: String, actual: String)
    case corruptStorage
    case destinationExists
    case invalidEdit
    case importDestinationNotEmpty
}

/// Filesystem-relative names only. These values are never shell arguments or URLs.
public struct GameRelativePath: Hashable, Codable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GameProjectError.invalidRelativePath
        }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Host-resolved identity. Imported manifests cannot grant access to either owner.
public enum GameProjectOwner: Codable, Hashable, Sendable {
    case space(recordID: UUID)
    case conversation(conversationID: UUID, workspaceID: UUID)
}

/// An opaque saved revision comes from the existing authoritative save service.
/// This value is not Codable and is not an authorization token. The App must
/// resolve access, root, environment and revision before creating/using it.
public struct GameProjectContext: Equatable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let rootURL: URL
    public let savedRevision: String
    /// An existing FloeEnvironments identifier; this package defines no environment types.
    public let environmentID: String?

    public init(projectID: UUID, owner: GameProjectOwner, rootURL: URL,
                savedRevision: String, environmentID: String? = nil) throws {
        guard rootURL.isFileURL, Self.validIdentifier(savedRevision),
              environmentID.map(Self.validIdentifier) ?? true else {
            throw GameProjectError.invalidContext
        }
        if case .space(let recordID) = owner, recordID != projectID {
            throw GameProjectError.invalidContext
        }
        self.projectID = projectID
        self.owner = owner
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.savedRevision = savedRevision
        self.environmentID = environmentID
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public func validate(current: Self) throws {
        let change: GameContextChange?
        if projectID != current.projectID { change = .project }
        else if owner != current.owner { change = .owner }
        else if rootURL != current.rootURL { change = .root }
        else if environmentID != current.environmentID { change = .environment }
        else if savedRevision != current.savedRevision { change = .revision }
        else { change = nil }
        if let change { throw GameProjectError.contextChanged(change) }
    }
}

public enum GameContextChange: String, Equatable, Sendable {
    case project, owner, root, environment, revision
}

public struct GameEngineEvidence: Equatable, Sendable {
    public enum Kind: String, Sendable { case projectMarker, dataLayout, packageDependency }
    public let path: GameRelativePath
    public let kind: Kind
    /// Metadata only; npm values are requirements, not resolved runtime versions.
    public let versionHint: String?
    public init(path: GameRelativePath, kind: Kind, versionHint: String? = nil) {
        self.path = path; self.kind = kind; self.versionHint = versionHint
    }
}

public struct GameEngineCandidate: Equatable, Sendable {
    public let engine: GameEngineID
    public let evidence: [GameEngineEvidence]
    public init(engine: GameEngineID, evidence: [GameEngineEvidence]) {
        self.engine = engine; self.evidence = evidence
    }
}

public struct GameProjectInspection: Sendable {
    public let rootURL: URL
    /// Nil for a read-only import probe. Planning requires a host-bound inspection.
    public let context: GameProjectContext?
    public let candidates: [GameEngineCandidate]
    /// Covers only inspected metadata, not a full-project revision or build proof.
    public let inspectedPaths: [GameRelativePath]
    /// Adapter metadata is not permission or proof of a successful build.
    public init(rootURL: URL, context: GameProjectContext?, candidates: [GameEngineCandidate],
                inspectedPaths: [GameRelativePath]) {
        self.rootURL = rootURL; self.context = context; self.candidates = candidates
        self.inspectedPaths = inspectedPaths
    }
}
