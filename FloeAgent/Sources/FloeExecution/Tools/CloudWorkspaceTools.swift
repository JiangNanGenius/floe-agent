import Foundation
import Crypto
import FloeCore
import FloeTools

public struct CloudWorkspaceArguments: Decodable, Sendable {
    public var hostID: String?
    public var path: String
    public var contentBase64: String?
    public var port: Int?
}

public struct CloudWorkspaceProvisionArguments: Decodable, Sendable {
    public var hostID: String?
    public var workspaceID: String?
    public var port: Int?
}

public struct CloudWorkspaceCatalogArguments: Decodable, Sendable {
    public var hostID: String?
    public var port: Int?

    public init(hostID: String? = nil, port: Int? = nil) {
        self.hostID = hostID
        self.port = port
    }
}

private enum CloudWorkspaceToolSupport {
    static let schema = #"{"type":"object","properties":{"hostID":{"type":"string","description":"Paired SSH host UUID; omit to use the default host"},"path":{"type":"string","description":"Path relative to the daemon cloud-workspace root"},"contentBase64":{"type":"string","description":"Base64 file content for writes"},"port":{"type":"integer","minimum":1,"maximum":65535}},"required":["path"],"additionalProperties":false}"#

    static func hostID(_ value: String?) throws -> UUID? {
        guard let value else { return nil }
        guard let id = UUID(uuidString: value) else { throw FloeError.validationFailed("hostID must be a UUID") }
        return id
    }

    static func output(_ data: Data) -> ToolExecutionOutput {
        let bounded = data.prefix(256 * 1024)
        let summary = String(decoding: bounded, as: UTF8.self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: summary, fullOutputSHA256: digest)
    }
}

/// Creates a daemon-owned top-level workspace. The ownership marker is what
/// permits later asynchronous cleanup; arbitrary user server directories can
/// never be recursively removed by a conversation deletion tombstone.
public struct CloudWorkspaceProvisionTool: AgentTool {
    public static let name = "cloudWorkspace.create"
    public static let toolDescription = "Create an isolated Floe-owned cloud workspace on a paired host. Omit workspaceID to generate one. Returns the stable workspace ID to link inside the task's local Cloud folder."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string","description":"Paired host UUID; omit to use the default host"},"workspaceID":{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"},"port":{"type":"integer","minimum":1,"maximum":65535}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceProvisionArguments) throws {
        _ = try CloudWorkspaceToolSupport.hostID(args.hostID)
    }
    public func execute(_ args: CloudWorkspaceProvisionArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var body: [String: String] = [:]
        if let workspaceID = args.workspaceID { body["workspace_id"] = workspaceID }
        let data = try await service.request(
            hostID: try CloudWorkspaceToolSupport.hostID(args.hostID),
            port: args.port ?? RemoteAgentPayload.defaultPort,
            method: "POST", endpoint: "v1/workspaces/create", body: body
        )
        return CloudWorkspaceToolSupport.output(data)
    }
}

/// Discovers existing Floe-owned remote workspaces without requiring the
/// model to remember or guess a workspace identifier from an older turn.
public struct CloudWorkspaceCatalogTool: AgentTool {
    public static let name = "cloudWorkspace.catalog"
    public static let toolDescription = "List Floe-owned cloud workspaces on a paired host. Returns stable workspaceID values for file and Git operations; use this when the current Workspace links do not already identify the target."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string","description":"Paired SSH host UUID; omit to use the default host"},"port":{"type":"integer","minimum":1,"maximum":65535}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let service: CloudWorkspaceService

    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceCatalogArguments) throws {
        _ = try CloudWorkspaceToolSupport.hostID(args.hostID)
    }
    public func execute(
        _ args: CloudWorkspaceCatalogArguments,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        let data = try await service.request(
            hostID: try CloudWorkspaceToolSupport.hostID(args.hostID),
            port: args.port ?? RemoteAgentPayload.defaultPort,
            method: "GET",
            endpoint: "v1/workspaces"
        )
        return CloudWorkspaceToolSupport.output(data)
    }
}

public struct CloudWorkspaceListTool: AgentTool {
    public static let name = "cloudWorkspace.list"
    public static let toolDescription = "List a directory in a linked cloud workspace through the verified SSH tunnel and Floe remote helper. This is read-only and does not expose the helper credential."
    public static let parametersJSON = CloudWorkspaceToolSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceArguments) throws { _ = try CloudWorkspaceToolSupport.hostID(args.hostID) }
    public func execute(_ args: CloudWorkspaceArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let data = try await service.request(hostID: try CloudWorkspaceToolSupport.hostID(args.hostID), port: args.port ?? RemoteAgentPayload.defaultPort, method: "GET", endpoint: "v1/files/list", queryPath: args.path)
        return CloudWorkspaceToolSupport.output(data)
    }
}

public struct CloudWorkspaceReadTool: AgentTool {
    public static let name = "cloudWorkspace.read"
    public static let toolDescription = "Read one bounded file from a linked cloud workspace through its verified SSH tunnel. Returns JSON containing base64 data and SHA-256."
    public static let parametersJSON = CloudWorkspaceToolSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceArguments) throws { _ = try CloudWorkspaceToolSupport.hostID(args.hostID) }
    public func execute(_ args: CloudWorkspaceArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let data = try await service.request(hostID: try CloudWorkspaceToolSupport.hostID(args.hostID), port: args.port ?? RemoteAgentPayload.defaultPort, method: "GET", endpoint: "v1/files/read", queryPath: args.path)
        return CloudWorkspaceToolSupport.output(data)
    }
}

public struct CloudWorkspaceWriteTool: AgentTool {
    public static let name = "cloudWorkspace.write"
    public static let toolDescription = "Atomically write a bounded file in a linked cloud workspace through the verified SSH tunnel. Requires contentBase64."
    public static let parametersJSON = CloudWorkspaceToolSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceArguments) throws {
        _ = try CloudWorkspaceToolSupport.hostID(args.hostID)
        guard let value = args.contentBase64, Data(base64Encoded: value) != nil else { throw FloeError.validationFailed("contentBase64 is required and must be valid base64") }
    }
    public func execute(_ args: CloudWorkspaceArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let data = try await service.request(hostID: try CloudWorkspaceToolSupport.hostID(args.hostID), port: args.port ?? RemoteAgentPayload.defaultPort, method: "POST", endpoint: "v1/files/write", body: ["path": args.path, "data_base64": args.contentBase64 ?? ""])
        return CloudWorkspaceToolSupport.output(data)
    }
}

public struct CloudWorkspaceCreateDirectoryTool: AgentTool {
    public static let name = "cloudWorkspace.createDirectory"
    public static let toolDescription = "Create a directory in a linked cloud workspace through the verified SSH tunnel."
    public static let parametersJSON = CloudWorkspaceToolSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceArguments) throws { _ = try CloudWorkspaceToolSupport.hostID(args.hostID) }
    public func execute(_ args: CloudWorkspaceArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let data = try await service.request(hostID: try CloudWorkspaceToolSupport.hostID(args.hostID), port: args.port ?? RemoteAgentPayload.defaultPort, method: "POST", endpoint: "v1/files/mkdir", body: ["path": args.path])
        return CloudWorkspaceToolSupport.output(data)
    }
}

public struct CloudWorkspaceGitArguments: Decodable, Sendable {
    public var hostID: String?
    public var workspaceID: String
    public var path: String?
    public var message: String?
    public var name: String?
    public var port: Int?
}

private enum CloudWorkspaceGitSupport {
    static let schema = #"{"type":"object","properties":{"hostID":{"type":"string","description":"Paired host UUID; omit to use the default host"},"workspaceID":{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"},"path":{"type":"string","description":"Optional path relative to the cloud workspace"},"message":{"type":"string","maxLength":8192},"name":{"type":"string","maxLength":200},"port":{"type":"integer","minimum":1,"maximum":65535}},"required":["workspaceID"],"additionalProperties":false}"#

    static func validate(_ args: CloudWorkspaceGitArguments) throws {
        _ = try CloudWorkspaceToolSupport.hostID(args.hostID)
        guard args.workspaceID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("workspaceID is invalid")
        }
    }

    static func execute(
        action: String,
        args: CloudWorkspaceGitArguments,
        service: CloudWorkspaceService
    ) async throws -> ToolExecutionOutput {
        var body = ["workspace_id": args.workspaceID, "action": action]
        if let path = args.path { body["path"] = path }
        if let message = args.message { body["message"] = message }
        if let name = args.name { body["name"] = name }
        let data = try await service.request(
            hostID: try CloudWorkspaceToolSupport.hostID(args.hostID),
            port: args.port ?? RemoteAgentPayload.defaultPort,
            method: "POST", endpoint: "v1/git", body: body
        )
        return CloudWorkspaceToolSupport.output(data)
    }
}

public struct CloudWorkspaceGitStatusTool: AgentTool {
    public static let name = "cloudWorkspace.gitStatus"
    public static let toolDescription = "Read Git branch and working-tree status in one Floe-owned cloud workspace. Read-only."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "status", args: args, service: service)
    }
}

public struct CloudWorkspaceGitDiffTool: AgentTool {
    public static let name = "cloudWorkspace.gitDiff"
    public static let toolDescription = "Read a bounded Git diff for an entire Floe-owned cloud workspace or one relative path."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "diff", args: args, service: service)
    }
}

public struct CloudWorkspaceGitLogTool: AgentTool {
    public static let name = "cloudWorkspace.gitLog"
    public static let toolDescription = "Read the latest 30 commits in a Floe-owned cloud workspace."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "log", args: args, service: service)
    }
}

public struct CloudWorkspaceGitInitializeTool: AgentTool {
    public static let name = "cloudWorkspace.gitInitialize"
    public static let toolDescription = "Initialize a Git repository with main as its first branch inside a Floe-owned cloud workspace."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "initialize", args: args, service: service)
    }
}

public struct CloudWorkspaceGitStageTool: AgentTool {
    public static let name = "cloudWorkspace.gitStage"
    public static let toolDescription = "Stage all changes or one relative path in a Floe-owned cloud workspace. Repository metadata cannot be targeted."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "stage", args: args, service: service)
    }
}

public struct CloudWorkspaceGitCommitTool: AgentTool {
    public static let name = "cloudWorkspace.gitCommit"
    public static let toolDescription = "Commit staged changes in a Floe-owned cloud workspace using the host's configured Git identity. Does not push."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws {
        try CloudWorkspaceGitSupport.validate(args)
        guard args.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw FloeError.validationFailed("message is required")
        }
    }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "commit", args: args, service: service)
    }
}

public struct CloudWorkspaceGitFetchTool: AgentTool {
    public static let name = "cloudWorkspace.gitFetch"
    public static let toolDescription = "Fetch remote refs in a cloud workspace using the cloud host's existing Git/SSH credential configuration; does not modify workspace files."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "fetch", args: args, service: service)
    }
}

public struct CloudWorkspaceGitPullTool: AgentTool {
    public static let name = "cloudWorkspace.gitPull"
    public static let toolDescription = "Perform a fast-forward-only pull in a Floe-owned cloud workspace. Never merges, rebases, resets or discards files."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "pull", args: args, service: service)
    }
}

public struct CloudWorkspaceGitPushTool: AgentTool {
    public static let name = "cloudWorkspace.gitPush"
    public static let toolDescription = "Push the current cloud-workspace branch without force using credentials already configured on the cloud host."
    public static let parametersJSON = CloudWorkspaceGitSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: CloudWorkspaceGitArguments) throws { try CloudWorkspaceGitSupport.validate(args) }
    public func execute(_ args: CloudWorkspaceGitArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CloudWorkspaceGitSupport.execute(action: "push", args: args, service: service)
    }
}

public struct CloudWorkspaceGitBranchTool: AgentTool {
    public static let name = "cloudWorkspace.gitBranch"
    public static let toolDescription = "Create or switch a cloud-workspace branch only while its working tree is clean. Set name and create=true to create."
    public struct Arguments: Decodable, Sendable {
        public var hostID: String?; public var workspaceID: String; public var name: String; public var create: Bool?; public var port: Int?
    }
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"},"workspaceID":{"type":"string"},"name":{"type":"string","maxLength":200},"create":{"type":"boolean","default":false},"port":{"type":"integer","minimum":1,"maximum":65535}},"required":["workspaceID","name"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesRemoteCommand]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: Arguments) throws { guard !args.name.isEmpty else { throw FloeError.validationFailed("name is required") } }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let generic = CloudWorkspaceGitArguments(hostID: args.hostID, workspaceID: args.workspaceID, path: nil, message: nil, name: args.name, port: args.port)
        try CloudWorkspaceGitSupport.validate(generic)
        return try await CloudWorkspaceGitSupport.execute(action: args.create == true ? "create_branch" : "switch_branch", args: generic, service: service)
    }
}
