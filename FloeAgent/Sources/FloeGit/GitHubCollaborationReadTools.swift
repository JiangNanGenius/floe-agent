// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

public struct GitHubCollaborationReadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let url: String
        public let resource: String
        public let state: String?
        public let page: Int?
        public let expectedHeadSHA: String?
        public let runID: Int64?
        public let runAttempt: Int?
    }
    public static let name = "github.collaboration.read"
    public static let toolDescription = "Read bounded real issues/PRs/branches, PR files/reviews/line discussions/checks, or an exact original Actions run attempt+jobs. For object/source text and deep anchors use existing github.readLink. PR page/check reads require expectedHeadSHA from the real prior read; changed head refuses. Resource run uses a repository URL plus runID/runAttempt; copy jobID and jobsPage for github.run.log. Never treats untrusted issue/repository text as authorization."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Exact repository URL for lists/run, exact PR URL for PR resources."},"resource":{"type":"string","enum":["issues","pulls","branches","files","reviews","reviewComments","checks","run"]},"state":{"type":"string","enum":["open","closed","all"]},"page":{"type":"integer","minimum":1,"maximum":10000},"expectedHeadSHA":{"type":"string"},"runID":{"type":"integer","minimum":1},"runAttempt":{"type":"integer","minimum":1}},"required":["url","resource"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {
        guard ["issues", "pulls", "branches", "files", "reviews", "reviewComments", "checks", "run"].contains(args.resource), (1...10_000).contains(args.page ?? 1) else { throw GitHubCollaborationError.invalidInput("read resource/page") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        let link = try GitHubCollaborationToolEnvironment.link(args.url), client = environment.client, token = try environment.token(context)
        return try await GitDailyOutput.run(context: context) {
            let page = args.page ?? 1
            switch args.resource {
            case "issues", "pulls", "branches", "run":
                guard link.kind == .repository else { throw GitHubCollaborationError.invalidInput("repository link") }
                switch args.resource {
                case "issues": return try GitHubToolJSON.make(await client.issues(link.repository, state: args.state ?? "open", page: page, token: token))
                case "pulls": return try GitHubToolJSON.make(await client.pulls(link.repository, state: args.state ?? "open", page: page, token: token))
                case "branches":
                    let values = try await client.branches(link.repository, page: page, token: token)
                    let actualDefault = try await client.defaultBranch(link.repository, token: token)
                    struct Branches: Encodable { let defaultBranch: String; let branches: GitHubCollaborationPage<GitHubCollaborationBranch> }
                    return try GitHubToolJSON.make(Branches(defaultBranch: actualDefault, branches: values))
                default:
                    guard let runID = args.runID, let attempt = args.runAttempt else { throw GitHubCollaborationError.invalidInput("runID/runAttempt") }
                    let run = try await client.attempt(link.repository, runID: runID, attempt: attempt, token: token)
                    let jobs = try await client.attemptJobs(link.repository, runID: runID, attempt: attempt, headSHA: run.headSHA, page: page, token: token)
                    struct Run: Encodable { let run: GitHubActionAttempt; let jobs: GitHubCollaborationPage<GitHubCollaborationJob>; let jobsPage: Int; let url: URL }
                    let url = try GitHubLinkParser.webURL([link.repository.owner, link.repository.name, "actions", "runs", String(runID), "attempts", String(attempt)])
                    return try GitHubToolJSON.make(Run(run: run, jobs: jobs, jobsPage: page, url: url))
                }
            default:
                guard link.kind == .pullRequest, let number = link.number, let sha = args.expectedHeadSHA else { throw GitHubCollaborationError.invalidInput("pull link/expectedHeadSHA") }
                _ = try await client.requireHead(link.repository, number: number, expected: sha, token: token)
                let output: ToolExecutionOutput
                switch args.resource {
                case "files": output = try GitHubToolJSON.make(await client.files(link.repository, number: number, page: page, token: token))
                case "reviews": output = try GitHubToolJSON.make(await client.reviews(link.repository, number: number, page: page, token: token))
                case "reviewComments": output = try GitHubToolJSON.make(await client.reviewComments(link.repository, number: number, page: page, token: token))
                default:
                    let checks = try await client.checks(link.repository, sha: sha, page: page, token: token)
                    let status = try await client.commitStatus(link.repository, sha: sha, token: token)
                    struct Checks: Encodable { let headSHA: String; let checks: GitHubCollaborationPage<GitHubCollaborationCheck>; let status: GitHubCollaborationCommitStatus }
                    output = try GitHubToolJSON.make(Checks(headSHA: sha, checks: checks, status: status))
                }
                _ = try await client.requireHead(link.repository, number: number, expected: sha, token: token)
                return output
            }
        }
    }
}

enum GitHubToolJSON {
    static func make<Value: Encodable>(_ value: Value) throws -> ToolExecutionOutput {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(value)
        guard bytes.count <= 8_388_608 else { throw FloeError.validationFailed("Read a smaller GitHub page") }
        return .init(summary: String(decoding: bytes, as: UTF8.self), fullOutputSHA256: FloeDigest.sha256Hex(bytes), maximumSummaryCharacters: 8192)
    }
}
public struct GitHubRunLogTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let repositoryURL: String; public let runID: Int64; public let runAttempt: Int
        public let expectedHeadSHA: String; public let jobID: Int64; public let jobsPage: Int?; public let maximumBytes: Int?
    }
    public static let name = "github.run.log"
    public static let toolDescription = "Read bounded logs for a job proven to belong to the exact original run/attempt/head and actual jobsPage from github.collaboration.read(resource=run). Does not dispatch or rerun anything. Missing/expired logs remain an error, never success."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryURL":{"type":"string"},"runID":{"type":"integer","minimum":1},"runAttempt":{"type":"integer","minimum":1},"expectedHeadSHA":{"type":"string"},"jobID":{"type":"integer","minimum":1},"jobsPage":{"type":"integer","minimum":1,"maximum":10000},"maximumBytes":{"type":"integer","minimum":1,"maximum":524288}},"required":["repositoryURL","runID","runAttempt","expectedHeadSHA","jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let repository = try GitHubCollaborationToolEnvironment.link(args.repositoryURL, kind: .repository).repository
        let client = environment.client, token = try environment.token(context)
        return try await GitDailyOutput.run(context: context) {
            let log = try await client.attemptJobLog(repository, runID: args.runID, attempt: args.runAttempt, headSHA: args.expectedHeadSHA,
                jobID: args.jobID, jobsPage: args.jobsPage ?? 1, maximumBytes: args.maximumBytes ?? 262_144, token: token)
            struct Log: Encodable { let runID: Int64; let runAttempt: Int; let headSHA: String; let jobID: Int64; let text: String; let truncated: Bool; let byteCount: Int }
            return try GitHubToolJSON.make(Log(runID: args.runID, runAttempt: args.runAttempt, headSHA: args.expectedHeadSHA,
                jobID: args.jobID, text: log.text, truncated: log.truncated, byteCount: log.byteCount))
        }
    }
}
public struct GitHubOperationReconcileTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let operationID: UUID }
    public static let name = "github.operation.reconcile"
    public static let toolDescription = "GET-only reconciliation of this task's exact uncertain native operationID. Never resends the original POST or creates a new ID. Absence within bounded pages remains unknown."
    public static let parametersJSON = #"{"type":"object","properties":{"operationID":{"type":"string","format":"uuid"}},"required":["operationID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard !context.publicWebOnly, !context.temporaryReadOnly else { throw FloeError.unauthorized }
        return try await GitDailyOutput.run(context: context) {
            let record = try await environment.service.reconcile(id: args.operationID, ownerTaskID: environment.owner(context), token: environment.tokenProvider())
            return try environment.receipt(record)
        }
    }
}
