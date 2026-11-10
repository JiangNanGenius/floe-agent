// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct GitHubCollaborationBranch: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let commit: Commit
    public var id: String { name }
    public struct Commit: Codable, Sendable, Hashable { public let sha: String }
}
extension GitHubCollaborationClient {
    private func branchResource<Value: Decodable & Sendable>(_ repository: GitHubLinkRepositoryID,
        suffix: [String], query: [URLQueryItem] = [], token: String) async throws -> Value {
        let parsed = try GitHubLinkParser.parse("https://github.com/" + repository.fullName)
        guard parsed.kind == .repository, parsed.repository == repository else { throw GitHubCollaborationError.invalidInput("repository") }
        let response = try await client.readLinkResource(["repos", repository.owner, repository.name] + suffix,
            query: query, token: token, maximumBytes: 4_194_304)
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw GitHubLinkError.invalidResponse("branch response") }
    }
    private func validBranch(_ branch: GitHubCollaborationBranch) throws {
        guard !branch.name.isEmpty, branch.name.utf8.count <= 1024,
              branch.name.rangeOfCharacter(from: .controlCharacters) == nil,
              [40, 64].contains(branch.commit.sha.utf8.count),
              branch.commit.sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GitHubLinkError.invalidResponse("branch identity")
        }
    }
    public func branches(_ repository: GitHubLinkRepositoryID, page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationBranch> {
        guard (1...10_000).contains(page) else { throw GitHubCollaborationError.invalidInput("page") }
        let items: [GitHubCollaborationBranch] = try await branchResource(repository, suffix: ["branches"],
            query: [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))], token: token)
        guard items.count <= 100 else { throw GitHubLinkError.invalidResponse("branch page") }
        for value in items { try validBranch(value) }
        return .init(items: items, page: page, nextPage: items.count == 100 ? page + 1 : nil)
    }
    public func branch(_ repository: GitHubLinkRepositoryID, name: String, token: String = "") async throws -> GitHubCollaborationBranch {
        guard !name.isEmpty, name.utf8.count <= 1024, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw GitHubCollaborationError.invalidInput("branch")
        }
        let value: GitHubCollaborationBranch = try await branchResource(repository, suffix: ["branches", name], token: token)
        try validBranch(value)
        guard value.name == name else { throw GitHubLinkError.invalidResponse("branch identity") }
        return value
    }
    public func defaultBranch(_ repository: GitHubLinkRepositoryID, token: String = "") async throws -> String {
        struct Metadata: Decodable, Sendable { let full_name: String; let default_branch: String }
        let value: Metadata = try await branchResource(repository, suffix: [], token: token)
        guard value.full_name.caseInsensitiveCompare(repository.fullName) == .orderedSame,
              !value.default_branch.isEmpty, value.default_branch.utf8.count <= 1024,
              value.default_branch.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw GitHubLinkError.invalidResponse("repository default branch")
        }
        return value.default_branch
    }
}
