import Foundation
import Crypto
import FloeCore
import FloeTools

public struct RemoteHostingArguments: Decodable, Sendable {
    public var hostID: String
    public var action: String?
    public var path: String?
    public var port: Int?
    public var domain: String?
    public var acmeEmail: String?
    public var acmeMethod: String?
    public var allowForwardedPrivate: Bool?
    public var manageFirewall: Bool?
    public var shareID: String?
}

private enum RemoteHostingSupport {
    static let schema = #"{"type":"object","properties":{"hostID":{"type":"string","description":"Paired host UUID"},"action":{"type":"string","enum":["plan","publish","list","stop"]},"path":{"type":"string","description":"Directory relative to the remote cloud-workspace root"},"port":{"type":"integer","minimum":1024,"maximum":65535},"domain":{"type":"string","description":"Optional domain. When provided Floe requests and renews an ACME certificate automatically; without it the share uses HTTP by address and port."},"acmeEmail":{"type":"string"},"acmeMethod":{"type":"string","enum":["standalone","nginx","webroot"],"description":"Host-specific ACME challenge chosen after inspection; defaults to standalone."},"allowForwardedPrivate":{"type":"boolean","description":"Explicitly allow a host detected as private when the user says it is reachable through forwarding."},"manageFirewall":{"type":"boolean","description":"Manage only the exact Floe-owned share port."},"shareID":{"type":"string"}},"required":["hostID"],"additionalProperties":false}"#

    static func host(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw FloeError.validationFailed("hostID must be a UUID") }
        return id
    }

    static func output(_ data: Data) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: String(decoding: data.prefix(256 * 1024), as: UTF8.self),
            fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}

/// Read-only discovery is deliberately separate so the model can inspect a
/// heterogeneous host before proposing an installation or sharing workflow.
public struct RemoteHostingInspectTool: AgentTool {
    public static let name = "remoteHosting.inspect"
    public static let toolDescription = "Inspect the paired Floe daemon for Docker, Nginx, ACME/certbot, firewall support, network scope, active shares and automatic certificate-maintenance status. Use this before proposing a host-specific workflow. Read-only."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"}},"required":["hostID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: RemoteHostingArguments) throws { _ = try RemoteHostingSupport.host(args.hostID) }
    public func execute(_ args: RemoteHostingArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let data = try await service.request(hostID: try RemoteHostingSupport.host(args.hostID), method: "GET", endpoint: "v1/capabilities")
        return RemoteHostingSupport.output(data)
    }
}

/// Model-led share orchestration. `plan` and `list` are harmless, while
/// `publish` and `stop` retain the descriptor's remote-system approval gate.
public struct RemoteHostingManageTool: AgentTool {
    public static let name = "remoteHosting.manage"
    public static let toolDescription = "Plan, publish, list, or stop a daemon-hosted website. The model should inspect first, ask for the user's sharing/domain authority, then call publish. A domain enables ACME HTTPS with automatic server-side renewal; no domain publishes HTTP by address and port. Floe changes only its recorded Nginx instance and firewall port."
    public static let parametersJSON = RemoteHostingSupport.schema
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    private let service: CloudWorkspaceService
    public init(service: CloudWorkspaceService) { self.service = service }
    public func validate(_ args: RemoteHostingArguments) throws {
        _ = try RemoteHostingSupport.host(args.hostID)
        guard ["plan", "publish", "list", "stop"].contains(args.action ?? "") else { throw FloeError.validationFailed("action is required") }
        if args.action == "publish", (args.path ?? "").isEmpty { throw FloeError.validationFailed("path is required for publish") }
        if args.action == "stop", (args.shareID ?? "").isEmpty { throw FloeError.validationFailed("shareID is required for stop") }
    }
    public func execute(_ args: RemoteHostingArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let hostID = try RemoteHostingSupport.host(args.hostID)
        let action = args.action ?? ""
        let data: Data
        switch action {
        case "list":
            data = try await service.request(hostID: hostID, method: "GET", endpoint: "v1/shares")
        case "stop":
            data = try await service.request(hostID: hostID, method: "POST", endpoint: "v1/shares/\(args.shareID ?? "")/stop", body: [:])
        case "plan", "publish":
            var body: [String: String] = [:]
            if let path = args.path { body["path"] = path }
            if let port = args.port { body["port"] = String(port) }
            if let domain = args.domain, !domain.isEmpty { body["domain"] = domain }
            if let email = args.acmeEmail, !email.isEmpty { body["acme_email"] = email }
            if let method = args.acmeMethod, !method.isEmpty { body["acme_method"] = method }
            body["allow_forwarded_private"] = String(args.allowForwardedPrivate == true)
            body["manage_firewall"] = String(args.manageFirewall == true)
            if action == "publish" { body["explicit_share_authority"] = "true" }
            data = try await service.request(hostID: hostID, method: "POST", endpoint: action == "plan" ? "v1/shares/plan" : "v1/shares", body: body)
        default: throw FloeError.validationFailed("Unsupported hosting action")
        }
        return RemoteHostingSupport.output(data)
    }
}
