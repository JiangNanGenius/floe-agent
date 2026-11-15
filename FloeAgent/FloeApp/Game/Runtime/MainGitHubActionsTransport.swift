// SPDX-License-Identifier: MPL-2.0
#if canImport(FloeGit)
import Foundation
import FloeCore
import FloeGit
import FloeGameBuildKit

/// Token provider over Main's existing Keychain-backed credential store. The
/// token is read per call and never stored in a plan, record or log.
public struct MainGitHubTokenProvider: GameBuildGitHubTokenProvider {
    private let store: GitHubCredentialStore

    public init(store: GitHubCredentialStore = .init()) {
        self.store = store
    }

    public func token() async throws -> String? {
        try store.token()
    }
}

/// `GameBuildGitHubActionsTransport` over Main's `GitHubActionsClient`.
/// Dispatch, run association, artifact download and cancellation all remain in
/// the existing client; this type only maps the wire models to build types.
public struct MainGitHubActionsTransport: GameBuildGitHubActionsTransport {
    private let client: GitHubActionsClient

    public init(client: GitHubActionsClient = .init()) {
        self.client = client
    }

    public func workflows(owner: String, repository: String, token: String)
        async throws -> [GameBuildCIWorkflowRef] {
        try await client.workflows(owner: owner, repository: repository, token: token).map {
            .init(id: $0.id, name: $0.name, path: $0.path)
        }
    }

    public func workflowRuns(owner: String, repository: String, workflowID: Int64,
                             branch: String, event: String, token: String)
        async throws -> [GameBuildCIRun] {
        try await client.workflowRuns(
            owner: owner, repository: repository, workflowID: workflowID,
            token: token, branch: branch, event: event, maxPages: 2
        ).map(Self.mapRun)
    }

    public func run(owner: String, repository: String, runID: Int64,
                    token: String) async throws -> GameBuildCIRun {
        Self.mapRun(try await client.run(owner: owner, repository: repository,
                                        runID: runID, token: token))
    }

    public func artifacts(owner: String, repository: String, runID: Int64,
                          token: String) async throws -> [GameBuildCIArtifact] {
        try await client.artifacts(owner: owner, repository: repository,
                                   runID: runID, token: token, maxPages: 3).map {
            .init(id: $0.id, name: $0.name, sizeInBytes: $0.sizeInBytes,
                  expired: $0.expired, digest: $0.digest)
        }
    }

    public func downloadArtifact(owner: String, repository: String, runID: Int64,
                                 artifactID: Int64, token: String,
                                 maximumBytes: Int) async throws -> Data {
        let artifacts = try await client.artifacts(
            owner: owner, repository: repository, runID: runID, token: token, maxPages: 3)
        guard let artifact = artifacts.first(where: { $0.id == artifactID }) else {
            throw GameBuildCIError.artifact("artifact identity not found")
        }
        guard !artifact.expired, artifact.sizeInBytes > 0,
              artifact.sizeInBytes <= Int64(maximumBytes) else {
            throw GameBuildCIError.artifact("artifact is expired, empty or too large")
        }
        return try await client.downloadArtifact(
            artifact: artifact, token: token,
            maxBytes: min(maximumBytes, Int(artifact.sizeInBytes) + 1)).data
    }

    public func triggerDispatch(owner: String, repository: String, workflowID: Int64,
                                ref: String, inputs: [String: String], token: String)
        async throws -> GameBuildCITrigger {
        let result = try await client.triggerDispatch(
            owner: owner, repository: repository, workflowID: workflowID,
            ref: ref, inputs: inputs, token: token)
        return .init(runID: result.runID, htmlURL: result.htmlURL)
    }

    public func cancelRun(owner: String, repository: String, runID: Int64,
                          token: String) async throws {
        try await client.cancelRun(owner: owner, repository: repository,
                                   runID: runID, token: token)
    }

    private static func mapRun(_ run: GitHubActionsRun) -> GameBuildCIRun {
        .init(id: run.id, workflowID: run.workflowID, status: run.status,
              conclusion: run.conclusion, headSHA: run.headSHA,
              headBranch: run.headBranch, event: run.event,
              createdAt: run.createdAt, htmlURL: run.htmlURL)
    }
}

/// Narrow missing Git-data operation: GitHub's blob API requires base64 for
/// binary files, while the current `GitHubActionsClient.createBlob` sends a
/// base64 string with `encoding: "utf-8"`. This extension uses the same
/// authenticated session/origin and sends `encoding: "base64"`. A matching
/// upstream patch is in `MainBinding/GitHubActionsClient-createBlob-base64.diff`.
public extension GitHubActionsClient {
    func createBlobBase64(owner: String, repository: String, content: String,
                          token: String) async throws -> String {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw GitHubActionsError.invalidConfiguration("invalid GitHub API origin")
        }
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(repository)
            .appendingPathComponent("git")
            .appendingPathComponent("blobs")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["content": content, "encoding": "base64"])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw GitHubActionsError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                message: "Git blob creation failed")
        }
        guard data.count <= GitHubActionsClient.maximumJSONBytes else {
            throw GitHubActionsError.responseTooLarge(limit: GitHubActionsClient.maximumJSONBytes)
        }
        struct Blob: Decodable { let sha: String }
        guard let blob = try? JSONDecoder().decode(Blob.self, from: data) else {
            throw GitHubActionsError.decoding("Git blob response")
        }
        return blob.sha
    }
}
#endif
