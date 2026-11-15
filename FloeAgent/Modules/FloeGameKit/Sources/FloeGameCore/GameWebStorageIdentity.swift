// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Stable Web storage scope for one host-resolved project owner, engine,
/// environment and selected game root. The saved revision and materialized root URL are deliberately
/// excluded: editing, rebuilding or moving a project must not hide the game's
/// own built-in saves. The UUID is used both as the exact custom-scheme origin
/// host and as the persistent `WKWebsiteDataStore` identifier. It is derived
/// only from non-Codable host context; project manifests and model-authored
/// metadata cannot choose or join another scope. The UUID is an RFC 9562
/// version 8 custom UUID derived from SHA-256 (not a name-based v5 UUID).
public struct GameWebStorageIdentity: Equatable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let engine: GameEngineID
    public let environmentID: String?
    public let gameRoot: String
    public let uuid: UUID

    public init(projectID: UUID, owner: GameProjectOwner, engine: GameEngineID,
                environmentID: String?, gameRoot: String = ".") throws {
        if case .space(let recordID) = owner, recordID != projectID {
            throw GameProjectError.invalidContext
        }
        if let environmentID, !GameProjectContext.validIdentifier(environmentID) {
            throw GameProjectError.invalidContext
        }
        self.projectID = projectID
        self.owner = owner
        self.engine = engine
        self.environmentID = environmentID
        if gameRoot != "." {
            let path = try GameRelativePath(gameRoot)
            guard !path.value.split(separator: "/").contains(where: { GameProjectReader.versionControlNames.contains($0.lowercased()) }) else {
                throw GameProjectError.invalidContext
            }
        }
        self.gameRoot = gameRoot
        uuid = Self.derive(projectID: projectID, owner: owner, engine: engine, environmentID: environmentID, gameRoot: gameRoot)
    }

    public init(context: GameProjectContext, engine: GameEngineID, gameRoot: String = ".") throws {
        try self.init(projectID: context.projectID, owner: context.owner, engine: engine,
                      environmentID: context.environmentID, gameRoot: gameRoot)
    }

    /// Lowercase UUID string used as the exact custom-scheme origin host.
    public var originHost: String { uuid.uuidString.lowercased() }

    private static func derive(projectID: UUID, owner: GameProjectOwner, engine: GameEngineID,
                               environmentID: String?, gameRoot: String) -> UUID {
        func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let environment = environmentID.map { "1:" + field($0) } ?? "0:"
        var parts = ["floe-game-web-storage-v1", field(projectID.uuidString.lowercased()),
                     field(engine.rawValue), environment]
        switch owner {
        case .space(let recordID):
            parts += [field("space"), field(recordID.uuidString.lowercased()), field("")]
        case .conversation(let conversationID, let workspaceID):
            parts += [field("conversation"), field(conversationID.uuidString.lowercased()),
                      field(workspaceID.uuidString.lowercased())]
        }
        // Preserve the existing UUID/origin for the repository-root game.
        // A nested game's logical path stays stable across edits/rebuilds.
        if gameRoot != "." { parts += [field("nested-game-root-v1"), field(gameRoot)] }
        let digest = GameDigest.sha256(Data(parts.joined().utf8))
        var bytes: [UInt8] = []
        var index = digest.startIndex
        for _ in 0..<16 {
            let end = digest.index(index, offsetBy: 2)
            bytes.append(UInt8(digest[index..<end], radix: 16)!)
            index = end
        }
        // RFC 9562 version 8 (custom, SHA-256-derived) with the RFC variant
        // bits. This is not a name-based v5 UUID, which would require SHA-1.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension GamePreparedArtifact {
    /// The host-resolved storage identity of this sealed artifact. Callers must
    /// still validate the artifact and current project context separately.
    public func storageIdentity() throws -> GameWebStorageIdentity {
        try GameWebStorageIdentity(context: source, engine: engine, gameRoot: gameRoot)
    }
}

/// Native snapshot slots use the same stable scope as the game's browser
/// saves. The directory is resolved by the existing host save service.
public enum GameWebSaveRepositories {
    public static func open(directory: URL, artifact: GamePreparedArtifact) throws -> FileGameSaveRepository {
        let identity = try artifact.storageIdentity()
        return try .init(directory: directory.appendingPathComponent(identity.originHost),
            projectID: identity.projectID, owner: identity.owner,
            maximumStateBytes: GameWebRuntimePolicy(engine: identity.engine).maximumStateBytes)
    }
}
