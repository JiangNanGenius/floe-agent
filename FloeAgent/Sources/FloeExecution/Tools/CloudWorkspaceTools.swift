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
