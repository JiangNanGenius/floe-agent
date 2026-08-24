import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools

public struct GitToolEnvironment: Sendable {
    public let rootProvider: @Sendable () -> URL?
    public let git: LocalGitService
    public let github: GitHubService
    public let credentials: GitHubCredentialStore

    public init(
        rootProvider: @escaping @Sendable () -> URL?,
        git: LocalGitService = LocalGitService(),
        github: GitHubService = GitHubService(),
        credentials: GitHubCredentialStore = GitHubCredentialStore()
    ) {
        self.rootProvider = rootProvider
        self.git = git
        self.github = github
        self.credentials = credentials
    }

    func root(context: ToolContext) throws -> URL {
        guard case .local = context.scope else {
            throw FloeError.validationFailed("Local Git tools require local workspace scope")
        }
        guard let root = context.workspaceRootURL ?? rootProvider() else {
            throw FloeError.notFound("workspace")
        }
        return root
    }

    func token(required: Bool) throws -> String? {
        let token = try credentials.token()
        if required, token == nil {
            throw FloeError.invalidConfiguration("Connect GitHub in Settings before using this tool")
        }
        return token
    }

    func identity() async throws -> (name: String, email: String) {
        guard let token = try token(required: true) else {
            throw FloeError.invalidConfiguration("Connect GitHub in Settings")
        }
        let account = try await github.account(token: token)
        return (account.name ?? account.login, "\(account.login)@users.noreply.github.com")
    }
}

@discardableResult
public func registerGitTools(
    rootProvider: @escaping @Sendable () -> URL?,
    registry: ToolRunnerRegistry = .shared
) -> GitToolEnvironment {
    let environment = GitToolEnvironment(rootProvider: rootProvider)
    ToolCatalog.register(GitStatusTool.self)
    ToolCatalog.register(GitDiffTool.self)
    ToolCatalog.register(GitLogTool.self)
    ToolCatalog.register(GitInitializeTool.self)
    ToolCatalog.register(GitStageTool.self)
    ToolCatalog.register(GitCommitTool.self)
    ToolCatalog.register(GitCreateBranchTool.self)
    ToolCatalog.register(GitSwitchBranchTool.self)
    ToolCatalog.register(GitFetchTool.self)
    ToolCatalog.register(GitPullTool.self)
    ToolCatalog.register(GitPushTool.self)
    ToolCatalog.register(GitHubRepositoriesTool.self)
    ToolCatalog.register(GitHubCloneTool.self)
    ToolCatalog.register(GitHubCreateRepositoryTool.self)

    registry.register(GitStatusTool(environment: environment))
    registry.register(GitDiffTool(environment: environment))
    registry.register(GitLogTool(environment: environment))
    registry.register(GitInitializeTool(environment: environment))
    registry.register(GitStageTool(environment: environment))
    registry.register(GitCommitTool(environment: environment))
    registry.register(GitCreateBranchTool(environment: environment))
    registry.register(GitSwitchBranchTool(environment: environment))
    registry.register(GitFetchTool(environment: environment))
    registry.register(GitPullTool(environment: environment))
    registry.register(GitPushTool(environment: environment))
    registry.register(GitHubRepositoriesTool(environment: environment))
    registry.register(GitHubCloneTool(environment: environment))
    registry.register(GitHubCreateRepositoryTool(environment: environment))
    return environment
}

private enum GitToolOutput {
    static func make<T: Encodable>(_ value: T) throws -> ToolExecutionOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(
            summary: String(decoding: data.prefix(256 * 1024), as: UTF8.self),
            fullOutputSHA256: digest
        )
    }

    static func text(_ value: String) -> ToolExecutionOutput {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: value, fullOutputSHA256: digest)
    }
}

public struct GitEmptyArguments: Decodable, Sendable { public init() {} }

public struct GitStatusTool: AgentTool {
    public typealias Arguments = GitEmptyArguments
    public static let name = "git.status"
    public static let toolDescription = "Inspect the current local workspace Git branch, remotes, changed files, branches, and recent commits. Read-only."
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try GitToolOutput.make(await environment.git.snapshot(at: environment.root(context: context)))
    }
}

public struct GitDiffTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let path: String? }
    public static let name = "git.diff"
    public static let toolDescription = "Read the bounded unified Git diff for the workspace or one workspace-relative file."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Optional workspace-relative file path"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if let path = args.path { try context.authorizeWorkspacePath(path) }
        return try GitToolOutput.text(await environment.git.diff(at: environment.root(context: context), path: args.path))
    }
}

public struct GitLogTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let limit: Int? }
    public static let name = "git.log"
    public static let toolDescription = "Read recent commit history from the local workspace repository."
    public static let parametersJSON = #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await environment.git.snapshot(at: environment.root(context: context), commitLimit: args.limit ?? 30)
        return try GitToolOutput.make(snapshot.recentCommits)
    }
}

public struct GitInitializeTool: AgentTool {
    public typealias Arguments = GitEmptyArguments
    public static let name = "git.initialize"
    public static let toolDescription = "Initialize a real Git repository in the current local workspace using the connected GitHub identity."
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let identity = try await environment.identity()
        let snapshot = try await environment.git.initialize(
            at: environment.root(context: context), authorName: identity.name, authorEmail: identity.email
        )
        return try GitToolOutput.make(snapshot)
    }
}

public struct GitStageTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let paths: [String]? }
    public static let name = "git.stage"
    public static let toolDescription = "Stage all workspace changes, or a bounded list of workspace-relative paths, in the real Git index."
    public static let parametersJSON = #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"maxItems":200,"description":"Omit to stage all changes"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { if let paths = args.paths, paths.count > 200 { throw FloeError.validationFailed("At most 200 paths can be staged") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.root(context: context)
        if let paths = args.paths, !paths.isEmpty {
            for path in paths { try context.authorizeWorkspacePath(path) }
            try await environment.git.stage(paths: paths, at: root)
        } else {
            guard context.allowedWorkspacePaths.isEmpty else {
                throw FloeError.validationFailed("Stage-all is not allowed for a path-restricted task")
            }
            try await environment.git.stageAll(at: root)
        }
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitCommitTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let message: String }
    public static let name = "git.commit"
    public static let toolDescription = "Create a real local Git commit from staged changes using the connected GitHub identity. Does not push."
    public static let parametersJSON = #"{"type":"object","properties":{"message":{"type":"string","minLength":1,"maxLength":8192}},"required":["message"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { if args.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FloeError.validationFailed("Commit message is required") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let identity = try await environment.identity()
        let value = try await environment.git.commit(
            at: environment.root(context: context), message: args.message,
            authorName: identity.name, authorEmail: identity.email
        )
        return try GitToolOutput.make(value)
    }
}

public struct GitBranchArguments: Decodable, Sendable { public let name: String }

public struct GitCreateBranchTool: AgentTool {
    public typealias Arguments = GitBranchArguments
    public static let name = "git.createBranch"
    public static let toolDescription = "Create and switch to a new local Git branch without overwriting an existing branch."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":200}},"required":["name"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.git.createBranch(at: environment.root(context: context), name: args.name)
        return try GitToolOutput.make(await environment.git.snapshot(at: environment.root(context: context)))
    }
}

public struct GitSwitchBranchTool: AgentTool {
    public typealias Arguments = GitBranchArguments
    public static let name = "git.switchBranch"
    public static let toolDescription = "Switch to an existing local branch only when the workspace is clean; never discards changes."
    public static let parametersJSON = GitCreateBranchTool.parametersJSON
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.root(context: context)
        try await environment.git.switchBranch(at: root, name: args.name)
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitFetchTool: AgentTool {
    public typealias Arguments = GitEmptyArguments
    public static let name = "git.fetch"
    public static let toolDescription = "Fetch GitHub origin refs and objects without changing workspace files."
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.root(context: context)
        try await environment.git.fetch(at: root, token: environment.token(required: false))
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitPullTool: AgentTool {
    public typealias Arguments = GitEmptyArguments
    public static let name = "git.pull"
    public static let toolDescription = "Perform a safe fast-forward-only pull from GitHub origin. Refuses dirty or diverged workspaces."
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.root(context: context)
        try await environment.git.pullFastForward(at: root, token: environment.token(required: false))
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitPushTool: AgentTool {
    public typealias Arguments = GitEmptyArguments
    public static let name = "git.push"
    public static let toolDescription = "Push the current branch to its GitHub origin without force and without rewriting history."
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.root(context: context)
        try await environment.git.push(at: root, token: environment.token(required: true))
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitHubRepositoriesTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let limit: Int? }
    public static let name = "github.repositories"
    public static let toolDescription = "List repositories accessible to the connected GitHub account. Read-only and never returns the credential."
    public static let parametersJSON = #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let token = try environment.token(required: true) else { throw FloeError.invalidConfiguration("Connect GitHub") }
        return try await GitToolOutput.make(environment.github.repositories(token: token, limit: args.limit ?? 100))
    }
}

public struct GitHubCloneTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let cloneURL: String; public let destination: String }
    public static let name = "github.clone"
    public static let toolDescription = "Clone a GitHub HTTPS repository into a new directory inside the current local workspace using in-memory Keychain authentication."
    public static let parametersJSON = #"{"type":"object","properties":{"cloneURL":{"type":"string","format":"uri"},"destination":{"type":"string","description":"New workspace-relative directory"}},"required":["cloneURL","destination"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { guard URL(string: args.cloneURL) != nil else { throw FloeError.validationFailed("cloneURL is invalid") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.authorizeWorkspacePath(args.destination)
        let root = try environment.root(context: context)
        guard let remote = URL(string: args.cloneURL) else { throw FloeError.validationFailed("cloneURL is invalid") }
        let destination = root.appendingPathComponent(args.destination).standardizedFileURL
        guard destination.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw FloeError.validationFailed("Clone destination escapes workspace") }
        try await environment.git.clone(from: remote, to: destination, token: environment.token(required: false))
        return GitToolOutput.text("cloned=\(args.destination)")
    }
}

public struct GitHubCreateRepositoryTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let name: String; public let isPrivate: Bool?; public let description: String? }
    public static let name = "github.createRepository"
    public static let toolDescription = "Create an empty repository in the connected GitHub account. Does not upload workspace files."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":100},"isPrivate":{"type":"boolean","default":true},"description":{"type":"string","maxLength":350}},"required":["name"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let token = try environment.token(required: true) else { throw FloeError.invalidConfiguration("Connect GitHub") }
        let repository = try await environment.github.createRepository(
            token: token, name: args.name, isPrivate: args.isPrivate ?? true, description: args.description
        )
        return try GitToolOutput.make(repository)
    }
}
