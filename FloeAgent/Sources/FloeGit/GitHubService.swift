import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

public actor GitHubService {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.github.com/")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func account(token: String) async throws -> GitHubAccount {
        let data = try await request(path: "user", token: token)
        let payload = try JSONDecoder.github.decode(AccountPayload.self, from: data)
        return GitHubAccount(
            login: payload.login,
            name: payload.name,
            avatarURL: payload.avatarURL.flatMap(URL.init(string:))
        )
    }

    public func repositories(token: String, limit: Int = 100) async throws -> [GitHubRepository] {
        let count = min(max(limit, 1), 100)
        let data = try await request(
            path: "user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=\(count)",
            token: token
        )
        return try JSONDecoder.github.decode([RepositoryPayload].self, from: data).compactMap { value in
            guard let cloneURL = URL(string: value.cloneURL),
                  let webURL = URL(string: value.htmlURL) else { return nil }
            return GitHubRepository(
                id: value.id,
                fullName: value.fullName,
                name: value.name,
                isPrivate: value.isPrivate,
                defaultBranch: value.defaultBranch,
                cloneURL: cloneURL,
                webURL: webURL,
                pushedAt: value.pushedAt
            )
        }
    }

    public func createRepository(
        token: String,
        name: String,
        isPrivate: Bool,
        description: String?
    ) async throws -> GitHubRepository {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("GitHub repository name is invalid")
        }
        var body: [String: Any] = ["name": trimmed, "private": isPrivate, "auto_init": false]
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["description"] = String(description.prefix(350))
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await request(path: "user/repos", method: "POST", token: token, body: data)
        let value = try JSONDecoder.github.decode(RepositoryPayload.self, from: response)
        guard let cloneURL = URL(string: value.cloneURL), let webURL = URL(string: value.htmlURL) else {
            throw FloeError.validationFailed("GitHub returned invalid repository URLs")
        }
        return GitHubRepository(
            id: value.id, fullName: value.fullName, name: value.name,
            isPrivate: value.isPrivate, defaultBranch: value.defaultBranch,
            cloneURL: cloneURL, webURL: webURL, pushedAt: value.pushedAt
        )
    }

    private func request(
        path: String,
        method: String = "GET",
        token: String,
        body: Data? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL), url.host == baseURL.host else {
            throw FloeError.validationFailed("Invalid GitHub API path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FloeError.syncUnavailable("GitHub did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorPayload.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw FloeError.syncUnavailable(
                "GitHub request failed (\(http.statusCode)): \(SecretRedactor.redact(String(message.prefix(512))))"
            )
        }
        return data
    }
}

private struct AccountPayload: Decodable {
    let login: String
    let name: String?
    let avatarURL: String?
    enum CodingKeys: String, CodingKey { case login, name; case avatarURL = "avatar_url" }
}

private struct RepositoryPayload: Decodable {
    let id: Int64
    let fullName: String
    let name: String
    let isPrivate: Bool
    let defaultBranch: String
    let cloneURL: String
    let htmlURL: String
    let pushedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case cloneURL = "clone_url"
        case htmlURL = "html_url"
        case pushedAt = "pushed_at"
    }
}

private struct ErrorPayload: Decodable { let message: String }

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
