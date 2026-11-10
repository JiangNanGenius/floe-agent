// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
public struct GitCheckoutRemoteTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let repositoryPath: String?
        public let remote: String
        public let remoteBranch: String
        public let localBranch: String
    }
    public static let name = "git.checkoutRemote"
    public static let toolDescription = "Safely check out one actual fetched remote branch as a new local tracking branch. Reads git.remotes/real remote branches first. Requires a clean tree and new local name; never resets an existing branch or force-checks out. If branch creation succeeded but checkout failed, retain that branch and inspect git.status before continuing."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"},"remote":{"type":"string"},"remoteBranch":{"type":"string"},"localBranch":{"type":"string"}},"required":["remote","remoteBranch","localBranch"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        try context.authorizeWorkspacePath(args.repositoryPath ?? ".")
        return try await GitDailyOutput.run(context: context) {
            try await GitDailyOutput.make(environment.git.checkoutRemote(at: root, remote: args.remote, remoteBranch: args.remoteBranch, localBranch: args.localBranch))
        }
    }
}

public struct GitRemoteBranchesTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public let repositoryPath: String?; public let remote: String }
    public static let name = "git.remoteBranches"
    public static let toolDescription = "List actual already fetched branch names for an existing remote. Call git.fetch if refs are not downloaded, then choose one returned name for git.checkoutRemote or git.upstream.set. Does not download or switch anything."
    public static let parametersJSON = #"{"type":"object","properties":{"repositoryPath":{"type":"string"},"remote":{"type":"string"}},"required":["remote"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let root = try environment.scopedRoot(context: context, repositoryPath: args.repositoryPath)
        return try await GitDailyOutput.run(context: context) {
            let branches = try await environment.git.remoteBranches(at: root, remote: args.remote)
            struct Result: Encodable { let remote: String; let branches: [String] }
            return try GitDailyOutput.make(Result(remote: args.remote, branches: branches))
        }
    }
}
