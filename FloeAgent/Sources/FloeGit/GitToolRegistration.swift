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
    public let remoteExecutor: GitRemoteToolExecutor?
    public let projectImporter: GitProjectImporter?

    public init(
        rootProvider: @escaping @Sendable () -> URL?,
        git: LocalGitService = .shared,
        github: GitHubService = GitHubService(),
        credentials: GitHubCredentialStore = GitHubCredentialStore(),
        remoteExecutor: GitRemoteToolExecutor? = nil, projectImporter: GitProjectImporter? = nil
    ) {
        self.rootProvider = rootProvider
        self.git = git
        self.github = github
        self.credentials = credentials
        self.remoteExecutor = remoteExecutor; self.projectImporter = projectImporter
    }

    func root(context: ToolContext) throws -> URL {
        guard case .local = context.scope else {
            throw FloeError.validationFailed("Local Git tools require local workspace scope")
        }
        guard !context.publicWebOnly, !context.temporaryReadOnly else { throw FloeError.unauthorized }
        guard let root = context.workspaceRootURL else {
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

    /// Commit identity: the connected GitHub account when one exists, else a
    /// local default so local commits never depend on a remote account.
    func identity() async throws -> (name: String, email: String) {
        // Existing per-repository identity wins in configureIfMissing. Local
        // commits must never wait on an unrelated GitHub account request.
        ("Floe", "floe@local.floeagent")
    }
}

@discardableResult
public func registerGitTools(
    rootProvider: @escaping @Sendable () -> URL?,
    registry: ToolRunnerRegistry = .shared,
    remoteExecutor: GitRemoteToolExecutor? = nil, projectImporter: GitProjectImporter? = nil
) -> GitToolEnvironment {
    let environment = GitToolEnvironment(rootProvider: rootProvider, remoteExecutor: remoteExecutor, projectImporter: projectImporter)
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
    ToolCatalog.register(GitHubReadLinkTool.self)
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
    registry.register(GitHubReadLinkTool(environment: environment))
    registry.register(GitHubCloneTool(environment: environment))
    registry.register(GitHubCreateRepositoryTool(environment: environment))
    registerGitDailyTools(environment: environment, registry: registry)
    ToolCatalog.register(GitCheckoutRemoteTool.self); registry.register(GitCheckoutRemoteTool(environment: environment))
    ToolCatalog.register(GitRemoteBranchesTool.self); registry.register(GitRemoteBranchesTool(environment: environment))
    ToolCatalog.register(GitCloneRepositoryTool.self); registry.register(GitCloneRepositoryTool(environment: environment))
    return environment
}

private enum GitToolOutput {
    static func make<T: Encodable>(_ value: T) throws -> ToolExecutionOutput {
        if let snapshot = value as? GitRepositorySnapshot { return try GitDailyOutput.status(snapshot) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let digest = FloeDigest.sha256Hex(data)
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: digest
        )
    }

    static func text(_ value: String) -> ToolExecutionOutput {
        let data = Data(value.utf8)
        let digest = FloeDigest.sha256Hex(data)
        return ToolExecutionOutput(summary: value, fullOutputSHA256: digest)
    }
}

public struct GitEmptyArguments: Decodable, Sendable { public let repositoryPath: String?; public init(repositoryPath: String? = nil) { self.repositoryPath = repositoryPath } }

public struct GitStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let repositoryPath: String?; public let offset: Int?; public let limit: Int? }
    public static let name = "git.status"
    public static let toolDescription = "Inspect the current local workspace Git branch, remotes, changed files, branches, and recent commits. Read-only."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":1000}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let snapshot = try await environment.git.snapshot(at: environment.scopedRoot(context: context, repositoryPath: args.repositoryPath))
        return try GitDailyOutput.status(snapshot, offset: args.offset ?? 0, limit: args.limit ?? 200)
    }
}

public struct GitDiffTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let path: String?; public let staged: Bool?; public let repositoryPath: String? }
    public static let name = "git.diff"
    public static let toolDescription = "Read the bounded unified Git diff for the workspace or one workspace-relative file."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"staged":{"type":"boolean"},"repositoryPath":{"type":"string"}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if let path = args.path { try environment.authorize([path], repositoryPath: args.repositoryPath, context: context) }
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try GitToolOutput.text(args.staged == true ? await environment.git.diffStaged(at: root, path: args.path) : await environment.git.diff(at: root, path: args.path))
    }
}

public struct GitLogTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let limit: Int?; public let repositoryPath: String?; public let offset: Int?; public let expectedHeadOID: String? }
    public static let name = "git.log"
    public static let toolDescription = "Read paged real commit history; copy headOID with nextOffset when continuing so a changed HEAD cannot silently skip or duplicate commits."
    public static let parametersJSON = #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":200},"repositoryPath":{"type":"string"},"offset":{"type":"integer","minimum":0},"expectedHeadOID":{"type":"string","description":"Copy headOID from the first history page when continuing; changed history refuses."}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let page = try await environment.git.history(at: environment.scopedRoot(context: context, repositoryPath: args.repositoryPath),
            offset: args.offset ?? 0, limit: args.limit ?? 30, expectedHeadOID: args.expectedHeadOID)
        return try GitToolOutput.make(page)
    }
}

public struct GitInitializeTool: AgentTool {
    public typealias Arguments = GitEmptyArguments
    public static let name = "git.initialize"
    public static let toolDescription = "Initialize a real Git repository in the current local workspace. Local only; no remote account or author sign-in is required."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await environment.git.initialize(at: environment.scopedRoot(context: context, repositoryPath: args.repositoryPath))
        return try GitToolOutput.make(snapshot)
    }
}

public struct GitStageTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let paths: [String]?; public let repositoryPath: String? }
    public static let name = "git.stage"
    public static let toolDescription = "Stage all workspace changes, or a bounded list of workspace-relative paths, in the real Git index."
    public static let parametersJSON = #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200},"repositoryPath":{"type":"string"}},"required":["paths"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { if let paths = args.paths, paths.count > 200 { throw FloeError.validationFailed("At most 200 paths can be staged") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let paths = args.paths, !paths.isEmpty else { throw FloeError.validationFailed("Choose explicit intended paths from git.status; never stage unrelated work") }
        try environment.authorize(paths, repositoryPath: args.repositoryPath, context: context)
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        try await environment.git.stage(paths: paths, at: root)
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitCommitTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let message: String; public let paths: [String]; public let expectedIndexRevision: String; public let expectedHeadOID: String?; public let repositoryPath: String? }
    public static let name = "git.commit"
    public static let toolDescription = "Create a real local Git commit from staged changes using the existing repository identity, otherwise a local default identity. Does not push."
    public static let parametersJSON = #"{"type":"object","properties":{"message":{"type":"string","minLength":1,"maxLength":8192},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200},"expectedIndexRevision":{"type":"string","description":"Copy indexRevision from actual git.status"},"expectedHeadOID":{"type":"string","description":"Copy headOID from actual git.status; omit only unborn HEAD"},"repositoryPath":{"type":"string"}},"required":["message","paths","expectedIndexRevision"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { if args.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FloeError.validationFailed("Commit message is required") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try environment.authorize(args.paths, repositoryPath: args.repositoryPath, context: context)
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        let identity = try await environment.identity(); try context.cancellation.throwIfCancelled()
        let value = try await environment.git.commitChecked(at: root, paths: args.paths,
            expectedIndexRevision: args.expectedIndexRevision, expectedHeadOID: args.expectedHeadOID,
            message: args.message, authorName: identity.name, authorEmail: identity.email)
        return try GitToolOutput.make(value)
    }
}

public struct GitBranchArguments: Decodable, Sendable { public let name: String; public let repositoryPath: String? }

public struct GitCreateBranchTool: AgentTool {
    public typealias Arguments = GitBranchArguments
    public static let name = "git.createBranch"
    public static let toolDescription = "Create and switch to a new local Git branch without overwriting an existing branch."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":200},"repositoryPath":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.git.createBranch(at: environment.scopedRoot(context: context, repositoryPath: args.repositoryPath), name: args.name)
        return try GitToolOutput.make(await environment.git.snapshot(at: environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)))
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
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        try await environment.git.switchBranch(at: root, name: args.name)
        return try GitToolOutput.make(await environment.git.snapshot(at: root))
    }
}

public struct GitRemoteToolArguments: Decodable, Sendable { public let repositoryPath: String?; public let remote: String?; public let merge: Bool?; public let destinationBranch: String? }

public struct GitFetchTool: AgentTool {
    public typealias Arguments = GitRemoteToolArguments
    public static let name = "git.fetch"
    public static let toolDescription = "Fetch the selected configured HTTPS/SSH remote without changing worktree files."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"},"remote":{"type":"string"},"merge":{"type":"boolean","description":"Pull only: permit ordinary merge when histories diverge"},"destinationBranch":{"type":"string","description":"Push only: explicit destination branch; no force"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        let upstream = try await environment.git.upstreamRemote(at: root)
        let remote = args.remote ?? upstream ?? "origin"
        let endpoint = try await environment.git.remoteEndpoint(at: root, name: remote, pushing: false)
        return try await GitDailyOutput.run(context: context) {
            try await environment.performRemote(endpoint: endpoint, context: context) { authentication in
                try context.cancellation.throwIfCancelled()
                try await environment.git.fetch(at: root, remoteName: remote, authentication: authentication)
                return try GitDailyOutput.make(await environment.git.snapshot(at: root))
            }
        }
    }
}

public struct GitPullTool: AgentTool {
    public typealias Arguments = GitRemoteToolArguments
    public static let name = "git.pull"
    public static let toolDescription = "Pull the current branch from its real upstream. Refuse dirty or changed workspaces. Default fast-forward only; merge=true preserves diverged histories via native merge."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"},"remote":{"type":"string"},"merge":{"type":"boolean","description":"Pull only: permit ordinary merge when histories diverge"},"destinationBranch":{"type":"string","description":"Push only: explicit destination branch; no force"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        let upstream = try await environment.git.upstreamRemote(at: root)
        let remote = args.remote ?? upstream ?? "origin"
        let endpoint = try await environment.git.remoteEndpoint(at: root, name: remote, pushing: false)
        return try await GitDailyOutput.run(context: context) {
            try await environment.performRemote(endpoint: endpoint, context: context) { authentication in
                try context.cancellation.throwIfCancelled()
                let identity = try await environment.identity(); try context.cancellation.throwIfCancelled()
                _ = try await environment.git.pull(at: root, remoteName: remote, authentication: authentication, merge: args.merge ?? false, authorName: identity.name, authorEmail: identity.email)
                return try GitDailyOutput.make(await environment.git.snapshot(at: root))
            }
        }
    }
}

public struct GitPushTool: AgentTool {
    public typealias Arguments = GitRemoteToolArguments
    public static let name = "git.push"
    public static let toolDescription = "Push to the selected configured HTTPS/SSH remote without force. Resolve unknown remote outcome before retrying; no GitHub requirement for generic repositories."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"},"remote":{"type":"string"},"merge":{"type":"boolean","description":"Pull only: permit ordinary merge when histories diverge"},"destinationBranch":{"type":"string","description":"Push only: explicit destination branch; no force"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        let upstream = try await environment.git.upstreamRemote(at: root)
        let remote = args.remote ?? upstream ?? "origin"
        let endpoint = try await environment.git.remoteEndpoint(at: root, name: remote, pushing: true)
        return try await GitDailyOutput.run(context: context) {
            try await environment.performRemote(endpoint: endpoint, context: context) { authentication in
                try context.cancellation.throwIfCancelled()
                try await environment.git.push(at: root, remoteName: remote, destinationBranch: args.destinationBranch, authentication: authentication)
                return try GitDailyOutput.make(await environment.git.snapshot(at: root))
            }
        }
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
    public struct Arguments: Decodable, Sendable { public let cloneURL: String; public let destination: String; public let repositoryPath: String? }
    public static let name = "github.clone"
    public static let toolDescription = "Clone a GitHub HTTPS repository into a new directory inside the current local workspace using in-memory Keychain authentication."
    public static let parametersJSON = #"{"type":"object","properties":{"cloneURL":{"type":"string","format":"uri"},"destination":{"type":"string","description":"New workspace-relative directory"}},"required":["cloneURL","destination"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { guard URL(string: args.cloneURL) != nil else { throw FloeError.validationFailed("cloneURL is invalid") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let endpoint = try GitRemoteEndpoint(args.cloneURL)
        guard endpoint.transport == .https, endpoint.host == "github.com" else { throw FloeError.validationFailed("Use git.clone for a generic HTTPS/SSH repository") }
        return try await GitCloneRepositoryTool(environment: environment).execute(.init(address: args.cloneURL, destination: args.destination, importAsProject: true), context: context)
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
