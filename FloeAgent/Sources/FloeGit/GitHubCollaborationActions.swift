// SPDX-License-Identifier: MPL-2.0
import Foundation
public struct GitHubCollaborationJob: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let runID: Int64
    public let headSHA: String
    public let name: String
    public let status: String
    public let conclusion: String?
    enum CodingKeys: String, CodingKey { case id, name, status, conclusion; case runID = "run_id", headSHA = "head_sha" }
}
extension GitHubCollaborationClient {
    private func actionResource<Value: Decodable & Sendable>(_ repository: GitHubLinkRepositoryID, suffix: [String],
        query: [URLQueryItem] = [], token: String) async throws -> Value {
        let parsed = try GitHubLinkParser.parse("https://github.com/" + repository.fullName)
        guard parsed.kind == .repository, parsed.repository == repository else { throw GitHubCollaborationError.invalidInput("repository") }
        let data = try await client.readLinkResource(["repos", repository.owner, repository.name, "actions"] + suffix,
            query: query, token: token, maximumBytes: 4_194_304)
        do { return try JSONDecoder().decode(Value.self, from: data.data) }
        catch { throw GitHubLinkError.invalidResponse("Actions response") }
    }
    public func attempt(_ repository: GitHubLinkRepositoryID, runID: Int64, attempt: Int, token: String = "") async throws -> GitHubActionAttempt {
        guard runID > 0, attempt > 0 else { throw GitHubCollaborationError.invalidInput("run attempt") }
        let value: GitHubActionAttempt = try await actionResource(repository, suffix: ["runs", String(runID), "attempts", String(attempt)], token: token)
        guard value.id == runID, value.runAttempt == attempt,
              [40, 64].contains(value.headSHA.utf8.count),
              value.headSHA.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GitHubLinkError.invalidResponse("run attempt identity") }
        return value
    }
    public func attemptJobs(_ repository: GitHubLinkRepositoryID, runID: Int64, attempt: Int, headSHA: String,
                            page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationJob> {
        guard runID > 0, attempt > 0, (1...10_000).contains(page) else { throw GitHubCollaborationError.invalidInput("jobs page") }
        struct Envelope: Decodable, Sendable { let total_count: Int; let jobs: [GitHubCollaborationJob] }
        let value: Envelope = try await actionResource(repository,
            suffix: ["runs", String(runID), "attempts", String(attempt), "jobs"],
            query: [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))], token: token)
        guard value.total_count >= 0, value.jobs.count <= 100,
              value.jobs.allSatisfy({ $0.id > 0 && $0.runID == runID && $0.headSHA == headSHA }) else { throw GitHubLinkError.invalidResponse("job identity") }
        return .init(items: value.jobs, page: page, nextPage: page * 100 < value.total_count ? page + 1 : nil)
    }
    /// The job ID must occur on this actual original attempt's actual page.
    /// GitHub's job detail response has no documented attempt field, so it is
    /// never used to infer that a current run owns a historical job.
    public func attemptJobLog(_ repository: GitHubLinkRepositoryID, runID: Int64, attempt: Int, headSHA: String,
                              jobID: Int64, jobsPage: Int, maximumBytes: Int = 262_144, token: String) async throws -> GitHubActionsLogSlice {
        guard (1...524_288).contains(maximumBytes), jobID > 0 else { throw GitHubCollaborationError.invalidInput("job log") }
        let actual = try await self.attempt(repository, runID: runID, attempt: attempt, token: token)
        guard actual.headSHA == headSHA else { throw GitHubCollaborationError.changedHead(expected: headSHA, actual: actual.headSHA) }
        let jobs = try await attemptJobs(repository, runID: runID, attempt: attempt, headSHA: headSHA, page: jobsPage, token: token)
        guard jobs.items.contains(where: { $0.id == jobID }) else { throw GitHubCollaborationError.invalidInput("job does not belong to the selected run attempt page") }
        try Task.checkCancellation()
        return try await client.jobLog(owner: repository.owner, repository: repository.name, jobID: jobID, token: token, maxBytes: maximumBytes)
    }
}
