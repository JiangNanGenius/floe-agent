// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A default destination for the next explicit Save to Space action. UUIDs and
/// revisions are routing metadata only. The host resolves both projects again;
/// this value can never grant file access or select an execution environment.
public struct GameProjectCopyLink: Codable, Equatable, Sendable {
    public let sourceProjectID: UUID
    public let sourceOwner: GameProjectOwner
    public let destinationSpaceID: UUID
    public let lastCopiedSourceRevision: String
    public let lastDestinationRevision: String

    public init(source: GameProjectContext, receipt: GameProjectTransferReceipt) throws {
        guard receipt.sourceProjectID == source.projectID, receipt.sourceRevision == source.savedRevision,
              source.projectID != receipt.project.projectID,
              case .space(let id) = receipt.project.owner, id == receipt.project.projectID,
              UUID(uuidString: receipt.sourceRevision) != nil,
              UUID(uuidString: receipt.project.revision) != nil else { throw GameProjectError.invalidContext }
        sourceProjectID = source.projectID; sourceOwner = source.owner; destinationSpaceID = id
        lastCopiedSourceRevision = receipt.sourceRevision; lastDestinationRevision = receipt.project.revision
    }

    func validate(source: GameProjectContext) throws {
        guard sourceProjectID == source.projectID, sourceOwner == source.owner,
              destinationSpaceID != sourceProjectID,
              UUID(uuidString: lastCopiedSourceRevision) != nil,
              UUID(uuidString: lastDestinationRevision) != nil else { throw GameProjectError.corruptStorage }
    }
}

/// One instance belongs to the App's shared project service. Preferences hold
/// the optional default, while the repositories own the completed copy and its
/// history. Losing this preference must not lose or roll back a saved project.
public actor GameProjectCopyLinkStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(suiteName: String? = nil, namespace: String = "floe.game.explicit-space-copy.v1") throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 200,
              !namespace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameProjectError.invalidContext
        }
        if let suiteName {
            guard !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) else { throw GameProjectError.invalidContext }
            self.defaults = defaults
        } else { defaults = .standard }
        prefix = namespace + "."
    }

    public func link(for source: GameProjectContext) throws -> GameProjectCopyLink? {
        guard let data = defaults.data(forKey: try key(source)) else { return nil }
        guard data.count <= 8_192 else { throw GameProjectError.corruptStorage }
        let link = try JSONDecoder().decode(GameProjectCopyLink.self, from: data)
        try link.validate(source: source)
        return link
    }

    /// The existing default is compared so a late Save completion cannot replace
    /// a more recently chosen destination. The caller can still surface its real
    /// completed receipt when this optional preference update loses the race.
    @discardableResult
    public func save(_ replacement: GameProjectCopyLink, for source: GameProjectContext,
                     expected: GameProjectCopyLink?) throws -> Bool {
        try replacement.validate(source: source)
        guard try link(for: source) == expected else { return false }
        let bytes = try JSONEncoder().encode(replacement)
        defaults.set(bytes, forKey: try key(source))
        guard try link(for: source) == replacement else { throw GameProjectError.io("copy destination preference") }
        return true
    }

    @discardableResult
    public func forget(for source: GameProjectContext, expected: GameProjectCopyLink) throws -> Bool {
        guard try link(for: source) == expected else { return false }
        defaults.removeObject(forKey: try key(source))
        return true
    }

    private func key(_ source: GameProjectContext) throws -> String {
        struct Identity: Encodable { let projectID: UUID; let owner: GameProjectOwner }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return prefix + GameDigest.sha256(try encoder.encode(Identity(projectID: source.projectID, owner: source.owner)))
    }
}
