// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools

public typealias GitRemoteToolExecutor = @Sendable (GitRemoteEndpoint, ToolContext, @escaping @Sendable (GitRemoteAuthentication) async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput
public typealias GitProjectImporter = @Sendable (URL, String?, ToolContext) async throws -> UUID

extension GitToolEnvironment {
    func scopedRoot(context: ToolContext, repositoryPath: String?) throws -> URL {
        try context.cancellation.throwIfCancelled()
        guard !context.publicWebOnly, !context.temporaryReadOnly else { throw FloeError.unauthorized }
        let base = try root(context: context)
        guard let relative = repositoryPath, !relative.isEmpty, relative != "." else { return base }
        guard !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator: "/").contains("..") else { throw FloeError.unauthorized }
        try context.authorizeWorkspacePath(relative)
        let result = base.appendingPathComponent(relative).standardizedFileURL
        guard result.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { throw FloeError.unauthorized }
        return result
    }
    func authorize(_ paths: [String], repositoryPath: String?, context: ToolContext) throws {
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw FloeError.unauthorized }
            let prefix = repositoryPath.flatMap { $0 == "." || $0.isEmpty ? nil : $0 }
            try context.authorizeWorkspacePath(prefix.map { $0 + "/" + path } ?? path)
        }
    }
    func performRemote(endpoint: GitRemoteEndpoint, context: ToolContext,
                       operation: @escaping @Sendable (GitRemoteAuthentication) async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if let remoteExecutor { return try await remoteExecutor(endpoint, context, operation) }
        let authentication: GitRemoteAuthentication
        if endpoint.transport == .https, endpoint.host == "github.com", endpoint.port == 443, let token = try token(required: false) {
            authentication = try .https(for: endpoint, username: "x-access-token", password: Data(token.utf8))
        } else { authentication = .anonymous(for: endpoint) }
        return try await operation(authentication)
    }
}

enum GitDailyOutput {
    private struct StatusPage: Encodable {
        let isRepository: Bool
        let branch: String?
        let headOID: String?
        let indexRevision: String?
        let remoteURL: String?
        let changes: [GitFileChange]
        let totalChangedEntries: Int
        let nextOffset: Int?
        let recentCommits: [GitCommitSummary]
    }
    static func status(_ snapshot: GitRepositorySnapshot, offset: Int = 0, limit: Int = 200) throws -> ToolExecutionOutput {
        guard offset >= 0, (1...1000).contains(limit) else { throw FloeError.validationFailed("Use a valid status page") }
        let end = min(snapshot.changes.count, offset + limit)
        let changes = offset < snapshot.changes.count ? Array(snapshot.changes[offset..<end]) : []
        return try make(StatusPage(isRepository: snapshot.isRepository, branch: snapshot.branch, headOID: snapshot.headOID,
            indexRevision: snapshot.indexRevision, remoteURL: snapshot.remoteURL, changes: changes,
            totalChangedEntries: snapshot.changes.count, nextOffset: end < snapshot.changes.count ? end : nil,
            recentCommits: Array(snapshot.recentCommits.prefix(30))))
    }
    static func make<Value: Encodable>(_ value: Value, unknown: Bool = false) throws -> ToolExecutionOutput {
        if let snapshot = value as? GitRepositorySnapshot { return try status(snapshot) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= 1_048_576 else { throw FloeError.validationFailed("Read fewer files or a smaller page before continuing") }
        return .init(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: FloeDigest.sha256Hex(data), maximumSummaryCharacters: 8192, outcomeUnknown: unknown)
    }
    static func run(context: ToolContext, operation: @escaping @Sendable () async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let worker = Task { try await operation() }
        let observer = Task {
            while !Task.isCancelled {
                if context.cancellation.isCancelled { worker.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { observer.cancel() }
        do { return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
        catch GitRemoteFailure.remoteOutcomeUnknown {
            return try make(["state": "unknown", "message": "Refresh the same remote reference before retrying. Do not repeat this push blindly."], unknown: true)
        }
    }
}

public struct GitUnstageTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let paths: [String]
        public let repositoryPath: String?
    }
    public static let name = "git.unstage"
    public static let toolDescription = "Remove only selected paths from the index; keep every worktree byte. Paths are relative to repositoryPath."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200}},"required":["paths"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            try environment.authorize(args.paths, repositoryPath: args.repositoryPath, context: context)
            try await environment.git.unstage(paths: args.paths, at: root)
            return try GitDailyOutput.make(await environment.git.snapshot(at: root))
        }
    }
}

public struct GitDiscardTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let paths: [String]
        public let includeStaged: Bool?
        public let repositoryPath: String?
    }
    public static let name = "git.discard"
    public static let toolDescription = "Discard only selected file changes after preserving real worktree/index recovery bytes. Return recoveryID; conflicts need git.conflict.read/resolve or git.abortMerge."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200},"includeStaged":{"type":"boolean"}},"required":["paths"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .deletesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            try environment.authorize(args.paths, repositoryPath: args.repositoryPath, context: context)
            return try await GitDailyOutput.make(environment.git.discard(paths: args.paths, at: root, includeStaged: args.includeStaged ?? false))
        }
    }
}

public struct GitMergeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let refName: String
        public let repositoryPath: String?
    }
    public static let name = "git.merge"
    public static let toolDescription = "Merge an existing exact local or remote-tracking ref without force/rebase. Return actual conflicts or merge commit state; read conflicts before resolving."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"refName":{"type":"string"}},"required":["refName"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            let identity = try await environment.identity(); try context.cancellation.throwIfCancelled()
            return try await GitDailyOutput.make(environment.git.mergeRef(at: root, refName: args.refName, authorName: identity.name, authorEmail: identity.email))
        }
    }
}

public struct GitConflictReadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let path: String
        public let repositoryPath: String?
    }
    public static let name = "git.conflict.read"
    public static let toolDescription = "Read real ancestor/current/incoming text, working result, headOID/indexRevision/worktreeSHA256 for one unresolved file. Never invent a missing side."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            try environment.authorize([args.path], repositoryPath: args.repositoryPath, context: context)
            return try await GitDailyOutput.make(environment.git.conflict(at: root, path: args.path))
        }
    }
}

public struct GitConflictResolveTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let path: String
        public let content: String?
        public let delete: Bool?
        public let expectedIndexRevision: String
        public let expectedWorktreeSHA256: String?
        public let expectedHeadOID: String?
        public let repositoryPath: String?
    }
    public static let name = "git.conflict.resolve"
    public static let toolDescription = "Resolve one current conflict from git.conflict.read. All expected fields must be copied from that read. A changed file/index/head or remaining conflict markers refuses before writing."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"path":{"type":"string"},"content":{"type":"string"},"delete":{"type":"boolean","description":"Set true only to resolve this conflict by deleting the file. Do not also supply content."},"expectedIndexRevision":{"type":"string"},"expectedWorktreeSHA256":{"type":"string"},"expectedHeadOID":{"type":"string"}},"required":["path","expectedIndexRevision"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard (args.delete == true && args.content == nil) || (args.delete != true && args.content != nil) else {
            throw FloeError.validationFailed("Supply content or an explicit delete=true, never both")
        }
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            try environment.authorize([args.path], repositoryPath: args.repositoryPath, context: context)
            let snapshot = try await environment.git.conflict(at: root, path: args.path)
            guard snapshot.indexRevision == args.expectedIndexRevision, snapshot.worktreeSHA256 == args.expectedWorktreeSHA256,
                  snapshot.headOID == args.expectedHeadOID else { throw FloeError.validationFailed("Conflict changed; read it again before resolving") }
            let identity = try await environment.identity(); try context.cancellation.throwIfCancelled()
            return try await GitDailyOutput.make(environment.git.resolveConflict(at: root, expected: snapshot, content: args.content, authorName: identity.name, authorEmail: identity.email))
        }
    }
}

public struct GitAbortMergeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let expectedIndexRevision: String
        public let expectedHeadOID: String?
        public let repositoryPath: String?
    }
    public static let name = "git.abortMerge"
    public static let toolDescription = "Abort only the current merge after validating the exact head/index from git.status. Preserve dirty bytes and merge metadata in recovery before native reset."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"expectedIndexRevision":{"type":"string"},"expectedHeadOID":{"type":"string"}},"required":["expectedIndexRevision"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .deletesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            guard try await environment.git.indexRevision(at: root) == args.expectedIndexRevision,
                  try await environment.git.headRevision(at: root) == args.expectedHeadOID else { throw FloeError.validationFailed("Merge state changed; read status again") }
            try context.cancellation.throwIfCancelled(); try await environment.git.abortMerge(at: root)
            return try GitDailyOutput.make(await environment.git.snapshot(at: root))
        }
    }
}

public struct GitRecoveryListTool: AgentTool {
    public struct Arguments: Decodable, Sendable {

        public let repositoryPath: String?
    }
    public static let name = "git.recovery.list"
    public static let toolDescription = "List actual native recovery receipts. completed=false is an interrupted backup and must not be claimed restorable automatically."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            return try await GitDailyOutput.make(environment.git.recoveries(at: root))
        }
    }
}

public struct GitRecoveryRestoreTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let recoveryID: String
        public let path: String
        public let layer: GitRecoveryLayer
        public let repositoryPath: String?
    }
    public static let name = "git.recovery.restore"
    public static let toolDescription = "Restore one verified worktree or staged version by actual recoveryID/path. Refuse newer destination/index bytes; other files remain untouched."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"recoveryID":{"type":"string"},"path":{"type":"string"},"layer":{"type":"string","enum":["worktree","index"]}},"required":["recoveryID","path","layer"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .deletesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            try environment.authorize([args.path], repositoryPath: args.repositoryPath, context: context)
            try await environment.git.restoreRecovery(at: root, id: args.recoveryID, path: args.path, layer: args.layer)
            return try GitDailyOutput.make(await environment.git.snapshot(at: root))
        }
    }
}

public struct GitRemotesTool: AgentTool {
    public struct Arguments: Decodable, Sendable {

        public let repositoryPath: String?
    }
    public static let name = "git.remotes"
    public static let toolDescription = "Read real configured fetch/push endpoints and the current upstream. Does not expose any secret URL or credential."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            struct Result: Encodable { let remotes: [Remote]; let upstream: String?; struct Remote: Encodable { let name: String; let fetch: String; let push: String } }
            let remotes = try await environment.git.remotes(at: root).map { Result.Remote(name: $0.name, fetch: $0.fetch.transportURL, push: $0.push.transportURL) }
            return try await GitDailyOutput.make(Result(remotes: remotes, upstream: environment.git.upstreamRemote(at: root)))
        }
    }
}

public struct GitSetRemoteTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let name: String
        public let fetchURL: String
        public let pushURL: String?
        public let repositoryPath: String?
    }
    public static let name = "git.remote.set"
    public static let toolDescription = "Set one named generic HTTPS/SSH remote. URLs must not contain passwords/tokens. Omitted pushURL follows fetchURL; never infer credentials from repository content."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"name":{"type":"string"},"fetchURL":{"type":"string"},"pushURL":{"type":"string"}},"required":["name","fetchURL"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            let fetch = try GitRemoteEndpoint(args.fetchURL), push = try args.pushURL.map(GitRemoteEndpoint.init)
            try context.cancellation.throwIfCancelled(); try await environment.git.setRemote(at: root, name: args.name, fetch: fetch, push: push)
            return try GitDailyOutput.make(["state": "configured", "remote": args.name])
        }
    }
}

public struct GitSetUpstreamTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let branch: String
        public let remote: String
        public let remoteBranch: String
        public let repositoryPath: String?
    }
    public static let name = "git.upstream.set"
    public static let toolDescription = "Set a local branch tracking an actually fetched remote branch. Fetch first if needed; do not switch a dirty workspace."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string","description":"Optional repository directory relative to this task workspace; use the repositoryPath returned by git.clone, never a UI-global project."},"branch":{"type":"string"},"remote":{"type":"string"},"remoteBranch":{"type":"string"}},"required":["branch","remote","remoteBranch"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            try await environment.git.setUpstream(at: root, branch: args.branch, remote: args.remote, remoteBranch: args.remoteBranch)
            return try GitDailyOutput.make(await environment.git.snapshot(at: root))
        }
    }
}

@discardableResult
public func registerGitDailyTools(environment: GitToolEnvironment, registry: ToolRunnerRegistry = .shared) -> GitToolEnvironment {
    ToolCatalog.register(GitCommitDetailsTool.self); registry.register(GitCommitDetailsTool(environment: environment))
    ToolCatalog.register(GitUnstageTool.self); registry.register(GitUnstageTool(environment: environment))
    ToolCatalog.register(GitDiscardTool.self); registry.register(GitDiscardTool(environment: environment))
    ToolCatalog.register(GitMergeTool.self); registry.register(GitMergeTool(environment: environment))
    ToolCatalog.register(GitConflictReadTool.self); registry.register(GitConflictReadTool(environment: environment))
    ToolCatalog.register(GitConflictResolveTool.self); registry.register(GitConflictResolveTool(environment: environment))
    ToolCatalog.register(GitAbortMergeTool.self); registry.register(GitAbortMergeTool(environment: environment))
    ToolCatalog.register(GitRecoveryListTool.self); registry.register(GitRecoveryListTool(environment: environment))
    ToolCatalog.register(GitRecoveryRestoreTool.self); registry.register(GitRecoveryRestoreTool(environment: environment))
    ToolCatalog.register(GitRemotesTool.self); registry.register(GitRemotesTool(environment: environment))
    ToolCatalog.register(GitSetRemoteTool.self); registry.register(GitSetRemoteTool(environment: environment))
    ToolCatalog.register(GitSetUpstreamTool.self); registry.register(GitSetUpstreamTool(environment: environment))
    return environment
}

public struct GitCommitDetailsTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let oid: String; public let repositoryPath: String?; public let offset: Int?; public let limit: Int? }
    public static let name = "git.commitDetails"
    public static let toolDescription = "Read an existing commit's exact parent IDs, message and first-parent patch (root commit against empty tree). A bounded patch reports diffTruncated; never assume the excerpt is the entire commit."
    public static let parametersJSON = #"{"type":"object","properties":{"oid":{"type":"string","description":"Exact commit object ID from git.log."},"repositoryPath":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":262144}},"required":["oid"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            let details = try await environment.git.commitDetails(at: root, oid: args.oid)
            let offset = args.offset ?? 0, limit = args.limit ?? 65_536
            guard offset >= 0, (1...262_144).contains(limit) else { throw FloeError.validationFailed("Use a valid diff page") }
            let text = String(details.diff.dropFirst(offset).prefix(limit))
            struct Page: Encodable {
                let oid: String; let message: String; let author: String; let date: Date
                let parentOIDs: [String]; let diff: String; let diffTruncated: Bool
                let offset: Int; let nextOffset: Int?
            }
            let end = offset + text.count
            return try GitDailyOutput.make(Page(oid: details.oid, message: details.message, author: details.author, date: details.date,
                parentOIDs: details.parentOIDs, diff: text, diffTruncated: details.diffTruncated,
                offset: offset, nextOffset: end < details.diff.count ? end : nil))
        }
    }
}
