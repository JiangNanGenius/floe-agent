import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

public struct GitHubDeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: TimeInterval
}

public actor GitHubService {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.github.com/")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func beginDeviceAuthorization(
        clientID: String,
        scope: String = "repo read:user"
    ) async throws -> GitHubDeviceAuthorization {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw FloeError.invalidConfiguration("GitHub 登录尚未配置 OAuth Client ID")
        }
        let payload: DeviceCodePayload = try await oauthFormRequest(
            url: URL(string: "https://github.com/login/device/code")!,
            fields: ["client_id": clientID, "scope": scope]
        )
        guard let verificationURL = URL(string: payload.verificationURI) else {
            throw FloeError.syncUnavailable("GitHub returned an invalid verification URL")
        }
        return GitHubDeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            interval: TimeInterval(max(1, payload.interval))
        )
    }

    public func completeDeviceAuthorization(
        _ authorization: GitHubDeviceAuthorization,
        clientID: String
    ) async throws -> String {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw FloeError.invalidConfiguration("GitHub 登录尚未配置 OAuth Client ID")
        }
        var interval = authorization.interval
        while Date() < authorization.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))
            let payload: DeviceTokenPayload = try await oauthFormRequest(
                url: URL(string: "https://github.com/login/oauth/access_token")!,
                fields: [
                    "client_id": clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]
            )
            if let token = payload.accessToken, !token.isEmpty { return token }
            switch payload.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + 5, TimeInterval(payload.interval ?? 0))
            case "access_denied":
                throw FloeError.cancelled
            case "expired_token":
                throw FloeError.syncUnavailable("GitHub 登录验证码已过期，请重新登录")
            case "device_flow_disabled":
                throw FloeError.invalidConfiguration("GitHub 应用尚未启用 Device Flow")
            default:
                let message = payload.errorDescription ?? payload.error ?? "unknown OAuth response"
                throw FloeError.syncUnavailable("GitHub login failed: \(SecretRedactor.redact(message))")
            }
        }
        throw FloeError.syncUnavailable("GitHub 登录验证码已过期，请重新登录")
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

    private func oauthFormRequest<T: Decodable>(
        url: URL,
        fields: [String: String]
    ) async throws -> T {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw FloeError.syncUnavailable("GitHub login endpoint is unavailable")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw FloeError.syncUnavailable("GitHub returned an invalid login response") }
    }
}

private struct DeviceCodePayload: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceTokenPayload: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?
    let interval: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
        case interval
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
