import Foundation
import FloeCore

/// Host-local package identity. The digest path stays immutable across an
/// index update; execution must use this path rather than a movable alias.
public struct RemoteSharedSkill: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String?
    public var repository: String
    public var ref: String
    public var subdirectory: String
    public var revision: String
    public var digest: String
    public var relativePath: String
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, version, repository, ref, subdirectory, revision, digest
        case relativePath = "relative_path"
        case updatedAt = "updated_at"
    }

    public var containerPath: String { "/opt/floe/skills/" + relativePath }
}

public enum RemoteSharedSkillsError: Error, Sendable {
    case updateRequired
    case invalidResponse
    case invalidReference
}

public struct RemoteSharedSkillDocument: Codable, Sendable, Equatable {
    public var skillID: String
    public var digest: String
    public var path: String
    public var content: String
    public var byteCount: Int

    enum CodingKeys: String, CodingKey {
        case digest, path, content
        case skillID = "skill_id"
        case byteCount = "byte_count"
    }
}

/// Uses the existing authenticated transport. Capability probes deliberately
/// do not invoke automatic daemon replacement on an in-use host.
public struct RemoteSharedSkillsService: Sendable {
    private let client: CloudWorkspaceService
    public init(client: CloudWorkspaceService) { self.client = client }

    public func isSupported(hostID: UUID) async throws -> Bool {
        struct Capabilities: Decodable {
            var sharedSkills: Bool?
            enum CodingKeys: String, CodingKey { case sharedSkills = "shared_skills" }
        }
        let data = try await client.requestJSON(hostID: hostID, method: "GET",
            endpoint: "v1/capabilities", ensureAgentReadiness: false)
        return try JSONDecoder().decode(Capabilities.self, from: data).sharedSkills == true
    }

    public func list(hostID: UUID) async throws -> [RemoteSharedSkill] {
        guard try await isSupported(hostID: hostID) else { throw RemoteSharedSkillsError.updateRequired }
        struct Listing: Decodable {
            var schemaVersion: Int
            var skills: [RemoteSharedSkill]
            enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version"; case skills }
        }
        let data = try await client.requestJSON(hostID: hostID, method: "GET",
            endpoint: "v1/skills", ensureAgentReadiness: false)
        let result = try JSONDecoder().decode(Listing.self, from: data)
        guard result.schemaVersion == 1,
              result.skills.allSatisfy(Self.isValid) else { throw RemoteSharedSkillsError.invalidResponse }
        return result.skills
    }

    public func pull(hostID: UUID, id: String, repository: String, ref: String,
                     subdirectory: String) async throws -> RemoteSharedSkill {
        guard Self.validID(id), !repository.isEmpty, !ref.isEmpty,
              Self.validPath(subdirectory, allowEmpty: true) else { throw RemoteSharedSkillsError.invalidReference }
        guard try await isSupported(hostID: hostID) else { throw RemoteSharedSkillsError.updateRequired }
        let body = try JSONSerialization.data(withJSONObject: [
            "id": id, "repository": repository, "ref": ref, "subdirectory": subdirectory
        ])
        let data = try await client.requestJSON(hostID: hostID, method: "POST",
            endpoint: "v1/skills/pull", body: body, ensureAgentReadiness: false)
        let result = try JSONDecoder().decode(RemoteSharedSkill.self, from: data)
        guard result.id == id, Self.isValid(result) else { throw RemoteSharedSkillsError.invalidResponse }
        return result
    }

    public func read(hostID: UUID, skill: RemoteSharedSkill, path: String = "SKILL.md") async throws -> RemoteSharedSkillDocument {
        guard Self.isValid(skill), Self.validPath(path, allowEmpty: false) else {
            throw RemoteSharedSkillsError.invalidReference
        }
        let data = try await client.requestJSON(hostID: hostID, method: "GET",
            endpoint: "v1/skills/\(skill.id)/versions/\(skill.digest)/read",
            queryPath: path, ensureAgentReadiness: false)
        let result = try JSONDecoder().decode(RemoteSharedSkillDocument.self, from: data)
        guard result.skillID == skill.id, result.digest == skill.digest, result.path == path,
              result.byteCount == result.content.utf8.count, result.byteCount <= 1_048_576 else {
            throw RemoteSharedSkillsError.invalidResponse
        }
        return result
    }

    public static func isValid(_ skill: RemoteSharedSkill) -> Bool {
        validID(skill.id) && skill.digest.count == 64
            && skill.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && skill.relativePath == "packages/\(skill.id)/\(skill.digest)"
            && !skill.revision.isEmpty
    }
    private static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
            && id != "." && id != ".."
    }
    private static func validPath(_ path: String, allowEmpty: Bool) -> Bool {
        (allowEmpty || !path.isEmpty) && !path.hasPrefix("/") && !path.hasPrefix("~")
            && !path.contains("\0") && !path.contains("\\")
            && !path.split(separator: "/").contains("..")
    }
}
