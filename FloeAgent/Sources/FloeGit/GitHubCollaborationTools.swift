// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools

public struct GitHubCollaborationToolEnvironment: Sendable {
    public let service: GitHubCollaborationService
    public let client: GitHubCollaborationClient
    public let tokenProvider: @Sendable () throws -> String
    public init(service: GitHubCollaborationService, client: GitHubCollaborationClient,
        tokenProvider: @escaping @Sendable () throws -> String = { try GitHubCredentialStore().token() ?? "" }) {
        self.service = service; self.client = client; self.tokenProvider = tokenProvider
    }
    func owner(_ context: ToolContext) -> UUID { context.conversationID ?? context.runID }
    func token(_ context: ToolContext) throws -> String {
        if context.publicWebOnly || context.temporaryReadOnly { return "" }
        return try tokenProvider()
    }
    static func link(_ raw: String, kind: GitHubLink.Kind? = nil) throws -> GitHubLink {
        let value = try GitHubLinkParser.parse(raw)
        guard kind == nil || value.kind == kind else { throw GitHubCollaborationError.invalidInput("link kind") }
        return value
    }
    static func operationID(_ context: ToolContext, tool: String) throws -> UUID {
        let call = !context.toolIdempotencyKey.isEmpty ? context.toolIdempotencyKey : context.toolCallID ?? ""
        guard !call.isEmpty else { throw FloeError.validationFailed("The runtime call identity is missing") }
        let digest = FloeDigest.sha256Hex(try JSONEncoder().encode(["github.native.operation.v1", context.runID.uuidString,
            context.conversationID?.uuidString ?? "", tool, call]))
        let raw = String(digest.prefix(32))
        let text = [raw.prefix(8), raw.dropFirst(8).prefix(4), raw.dropFirst(12).prefix(4), raw.dropFirst(16).prefix(4), raw.dropFirst(20)].map(String.init).joined(separator: "-")
        guard let id = UUID(uuidString: text) else { throw FloeError.internalError("Invalid native operation identity") }; return id
    }
    private struct Receipt: Encodable {
        let operationID: UUID
        let repository: GitHubLinkRepositoryID
        let kind: GitHubPreparedMutation.Kind
        let state: GitHubMutationRecord.State
        let result: GitHubMutationResult?
        let rejectionStatus: Int?
        let message: String?
    }
    func receipt(_ record: GitHubMutationRecord, message: String? = nil, userAction: Bool = false) throws -> ToolExecutionOutput {
        var output = try GitDailyOutput.make(Receipt(operationID: record.id, repository: record.request.repository,
            kind: record.request.kind, state: record.state, result: record.result,
            rejectionStatus: record.rejectionStatus, message: message), unknown: record.state == .unknown || record.state == .sending)
        output.requiresUserAction = userAction
        if record.state == .rejected { output.exitStatus = 1 }
        return output
    }
    func mutate(context: ToolContext, tool: String,
        prepare: @escaping @Sendable (UUID, UUID) throws -> GitHubPreparedMutation) async throws -> ToolExecutionOutput {
        guard !context.publicWebOnly, !context.temporaryReadOnly else { throw FloeError.unauthorized }
        let id = try Self.operationID(context, tool: tool), owner = owner(context), service = service
        return try await GitDailyOutput.run(context: context) {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let request = try prepare(id, owner)
            let prior = try await service.prepare(request, ownerTaskID: owner)
            if prior.state == .acknowledged { return try receipt(prior) }
            if prior.state == .unknown || prior.state == .sending { return try receipt(prior, message: "Use github.operation.reconcile for this same operationID. Do not submit a new operation.") }
            if prior.state == .rejected { return try receipt(prior, message: "GitHub rejected this operation. Correct the cause before authorizing a new action.") }
            let token = try tokenProvider()
            if token.isEmpty { return try receipt(prior, message: "Connect GitHub in the existing account settings, then continue this task.", userAction: true) }
            do {
                _ = try await service.execute(id: id, ownerTaskID: owner, token: token, authorize: {
                    try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
                })
            } catch GitHubCollaborationError.outcomeUnknown {
                // The service has saved the exact remote identity and an
                // uncertain receipt. Return the native no-replay signal.
            } catch GitHubCollaborationError.rejected {
                // Keep the original draft and explicit rejected result.
            }
            guard let result = await service.recent(ownerTaskID: owner).first(where: { $0.id == id }) else { throw FloeError.storageCorrupted("Missing GitHub delivery receipt") }
            return try receipt(result)
        }
    }
}

public struct GitHubIssueCreateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let repositoryURL: String
        public let title: String
        public let body: String
    }
    public static let name = "github.issue.create"
    public static let toolDescription = "Create one task-owned issue, preserving a durable draft and independently reading the actual issue back. Unknown outcomes return operationID and prohibit blind resend."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryURL":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"title":{"type":"string","maxLength":256},"body":{"type":"string","maxLength":64000}},"required":["repositoryURL","title","body"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let repo = try GitHubCollaborationToolEnvironment.link(args.repositoryURL, kind: .repository).repository
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .issue(id: id, ownerTaskID: owner, repository: repo, title: args.title, body: args.body)
        }
    }
}

public struct GitHubIssueStateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let url: String
        public let closed: Bool
    }
    public static let name = "github.issue.update"
    public static let toolDescription = "Close or reopen the exact issue, using the existing task authorization and independent state readback. Does not change a PR."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"closed":{"type":"boolean"}},"required":["url","closed"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let link = try GitHubCollaborationToolEnvironment.link(args.url, kind: .issue)
        guard let number = link.number else { throw GitHubCollaborationError.invalidInput("issue") }
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .issueState(id: id, ownerTaskID: owner, repository: link.repository, number: number, closed: args.closed)
        }
    }
}

public struct GitHubReplyTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let url: String
        public let body: String
    }
    public static let name = "github.issue.reply"
    public static let toolDescription = "Post a general timeline reply to the exact issue or PR. Line reviews use github.pull.comment; uncertain sends must be reconciled, never repeated with a new ID."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"body":{"type":"string","maxLength":64000}},"required":["url","body"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let link = try GitHubCollaborationToolEnvironment.link(args.url)
        guard [.issue, .pullRequest].contains(link.kind), let number = link.number else { throw GitHubCollaborationError.invalidInput("discussion") }
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .reply(id: id, ownerTaskID: owner, repository: link.repository, number: number, body: args.body)
        }
    }
}

public struct GitHubPullCreateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let repositoryURL: String
        public let title: String
        public let body: String
        public let head: String
        public let base: String
        public let expectedHeadSHA: String
        public let draft: Bool?
        public let headRepository: String?
    }
    public static let name = "github.pull.create"
    public static let toolDescription = "Create an exact head/base PR after actual source-branch SHA preflight. Use owner:branch for forks and headRepository for a differently named fork. This does not push code."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryURL":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"title":{"type":"string","maxLength":256},"body":{"type":"string","maxLength":64000},"head":{"type":"string"},"base":{"type":"string"},"expectedHeadSHA":{"type":"string","pattern":"^[0-9a-f]{40,64}$","description":"Exact actual head SHA from the prior native read, never guessed."},"draft":{"type":"boolean"},"headRepository":{"type":"string","description":"Source repository name (not owner/name), paired with owner:branch head."}},"required":["repositoryURL","title","body","head","base","expectedHeadSHA"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let repo = try GitHubCollaborationToolEnvironment.link(args.repositoryURL, kind: .repository).repository
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .pull(id: id, ownerTaskID: owner, repository: repo, title: args.title, body: args.body,
                head: args.head, base: args.base, headSHA: args.expectedHeadSHA, draft: args.draft ?? false, headRepository: args.headRepository)
        }
    }
}

public struct GitHubPullReviewTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let url: String
        public let expectedHeadSHA: String
        public let event: GitHubReviewEvent
        public let body: String
    }
    public static let name = "github.pull.review"
    public static let toolDescription = "Publish a PR review bound to the exact current commit: COMMENT, APPROVE or REQUEST_CHANGES. A changed head refuses before POST."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"expectedHeadSHA":{"type":"string","pattern":"^[0-9a-f]{40,64}$","description":"Exact actual head SHA from the prior native read, never guessed."},"event":{"type":"string","enum":["COMMENT","APPROVE","REQUEST_CHANGES"]},"body":{"type":"string","maxLength":64000}},"required":["url","expectedHeadSHA","event","body"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let link = try GitHubCollaborationToolEnvironment.link(args.url, kind: .pullRequest)
        guard let number = link.number else { throw GitHubCollaborationError.invalidInput("pull request") }
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .review(id: id, ownerTaskID: owner, repository: link.repository, number: number, headSHA: args.expectedHeadSHA, event: args.event, body: args.body)
        }
    }
}

public struct GitHubPullLineCommentTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let url: String
        public let expectedHeadSHA: String
        public let path: String
        public let line: Int
        public let side: GitHubReviewLine.Side
        public let startLine: Int?
        public let body: String
    }
    public static let name = "github.pull.comment"
    public static let toolDescription = "Comment on a real current PR diff line. Copy path/line/side and expectedHeadSHA from the actual patch; binary/missing/truncated patches cannot invent a valid anchor."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"expectedHeadSHA":{"type":"string","pattern":"^[0-9a-f]{40,64}$","description":"Exact actual head SHA from the prior native read, never guessed."},"path":{"type":"string"},"line":{"type":"integer","minimum":1},"side":{"type":"string","enum":["LEFT","RIGHT"]},"startLine":{"type":"integer","minimum":1},"body":{"type":"string","maxLength":64000}},"required":["url","expectedHeadSHA","path","line","side","body"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let link = try GitHubCollaborationToolEnvironment.link(args.url, kind: .pullRequest)
        guard let number = link.number else { throw GitHubCollaborationError.invalidInput("pull request") }
        let line = GitHubReviewLine(path: args.path, side: args.side, line: args.line, startLine: args.startLine)
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .lineComment(id: id, ownerTaskID: owner, repository: link.repository, number: number, headSHA: args.expectedHeadSHA, line: line, body: args.body)
        }
    }
}

public struct GitHubPullMergeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let url: String
        public let expectedHeadSHA: String
        public let method: GitHubMergeMethod
    }
    public static let name = "github.pull.merge"
    public static let toolDescription = "Merge the exact current PR head with GitHub server SHA compare-and-set. Branch protection/check/review permissions remain authoritative; local worktree and issue closure are separate results."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"expectedHeadSHA":{"type":"string","pattern":"^[0-9a-f]{40,64}$","description":"Exact actual head SHA from the prior native read, never guessed."},"method":{"type":"string","enum":["merge","squash","rebase"]}},"required":["url","expectedHeadSHA","method"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let link = try GitHubCollaborationToolEnvironment.link(args.url, kind: .pullRequest)
        guard let number = link.number else { throw GitHubCollaborationError.invalidInput("pull request") }
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .merge(id: id, ownerTaskID: owner, repository: link.repository, number: number, headSHA: args.expectedHeadSHA, method: args.method)
        }
    }
}

public struct GitHubRunRerunTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let repositoryURL: String
        public let runID: Int64
        public let runAttempt: Int
        public let expectedHeadSHA: String
        public let failedOnly: Bool?
    }
    public static let name = "github.run.rerun"
    public static let toolDescription = "Rerun the original GitHub Actions run, not a new dispatch. Rechecks actual latest runAttempt/headSHA before sending once; unknown outcome must reconcile."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryURL":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"runID":{"type":"integer","minimum":1},"runAttempt":{"type":"integer","minimum":1},"expectedHeadSHA":{"type":"string","pattern":"^[0-9a-f]{40,64}$","description":"Exact actual head SHA from the prior native read, never guessed."},"failedOnly":{"type":"boolean"}},"required":["repositoryURL","runID","runAttempt","expectedHeadSHA"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let repo = try GitHubCollaborationToolEnvironment.link(args.repositoryURL, kind: .repository).repository
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .rerun(id: id, ownerTaskID: owner, repository: repo, runID: args.runID, attempt: args.runAttempt, headSHA: args.expectedHeadSHA, failedOnly: args.failedOnly ?? true)
        }
    }
}

public struct GitHubRunCancelTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let repositoryURL: String
        public let runID: Int64
        public let runAttempt: Int
        public let expectedHeadSHA: String
    }
    public static let name = "github.run.cancel"
    public static let toolDescription = "Cancel the exact original Actions run after current runAttempt/head preflight; never cancels another run or treats an expired local view as remote failure."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryURL":{"type":"string","description":"Exact GitHub repository/object URL; never an API path or credential URL."},"runID":{"type":"integer","minimum":1},"runAttempt":{"type":"integer","minimum":1},"expectedHeadSHA":{"type":"string","pattern":"^[0-9a-f]{40,64}$","description":"Exact actual head SHA from the prior native read, never guessed."}},"required":["repositoryURL","runID","runAttempt","expectedHeadSHA"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitHubCollaborationToolEnvironment
    public init(environment: GitHubCollaborationToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let repo = try GitHubCollaborationToolEnvironment.link(args.repositoryURL, kind: .repository).repository
        return try await environment.mutate(context: context, tool: Self.name) { id, owner in
            try .cancelRun(id: id, ownerTaskID: owner, repository: repo, runID: args.runID, attempt: args.runAttempt, headSHA: args.expectedHeadSHA)
        }
    }
}

@discardableResult
public func registerGitHubCollaborationTools(environment: GitHubCollaborationToolEnvironment, registry: ToolRunnerRegistry = .shared) -> GitHubCollaborationToolEnvironment {
    ToolCatalog.register(GitHubIssueCreateTool.self); registry.register(GitHubIssueCreateTool(environment: environment))
    ToolCatalog.register(GitHubIssueStateTool.self); registry.register(GitHubIssueStateTool(environment: environment))
    ToolCatalog.register(GitHubReplyTool.self); registry.register(GitHubReplyTool(environment: environment))
    ToolCatalog.register(GitHubPullCreateTool.self); registry.register(GitHubPullCreateTool(environment: environment))
    ToolCatalog.register(GitHubPullReviewTool.self); registry.register(GitHubPullReviewTool(environment: environment))
    ToolCatalog.register(GitHubPullLineCommentTool.self); registry.register(GitHubPullLineCommentTool(environment: environment))
    ToolCatalog.register(GitHubPullMergeTool.self); registry.register(GitHubPullMergeTool(environment: environment))
    ToolCatalog.register(GitHubRunRerunTool.self); registry.register(GitHubRunRerunTool(environment: environment))
    ToolCatalog.register(GitHubRunCancelTool.self); registry.register(GitHubRunCancelTool(environment: environment))
    ToolCatalog.register(GitHubCollaborationReadTool.self); registry.register(GitHubCollaborationReadTool(environment: environment))
    ToolCatalog.register(GitHubRunLogTool.self); registry.register(GitHubRunLogTool(environment: environment))
    ToolCatalog.register(GitHubOperationReconcileTool.self); registry.register(GitHubOperationReconcileTool(environment: environment))
    return environment
}
