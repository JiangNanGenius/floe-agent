import Foundation
import Crypto
import FloeCore
import FloeTools

/// Plans, checks, installs, or updates Floe's loopback-only remote workspace
/// helper. The installer is fixed, verified and atomically rolled back, so
/// automatic mode treats its check/update as normal Floe maintenance.
public struct SSHBootstrapRemoteAgentTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String?
        public var operation: String?
        /// Backward-compatible input used by older model prompts.
        public var apply: Bool?

        public init(hostID: String? = nil, operation: String? = nil, apply: Bool? = nil) {
            self.hostID = hostID
            self.operation = operation
            self.apply = apply
        }
    }

    public static let name = "ssh.bootstrapFloeRemoteAgent"
    public static let toolDescription =
        "Plan, check, or install/update Floe's bundled remote workspace helper on a paired long-lived Linux host. Floe automatically verifies and atomically updates this fixed helper before helper-backed work, without a separate approval prompt. It binds only to 127.0.0.1, uses Floe's verified SSH tunnel, stores no SSH password, opens no firewall port, and rolls back a failed replacement. Default is plan-only."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"},"operation":{"type":"string","enum":["plan","check","installOrUpdate"],"description":"Plan by default; check is read-only; installOrUpdate performs Floe's verified atomic maintenance update without a separate approval prompt"},"apply":{"type":"boolean","description":"Deprecated compatibility flag: true means installOrUpdate"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: SSHCommandService
    public init(service: SSHCommandService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        if let hostID = args.hostID, UUID(uuidString: hostID) == nil {
            throw FloeError.validationFailed("hostID must be a UUID when provided")
        }
        if let operation = args.operation,
           !["plan", "check", "installOrUpdate"].contains(operation) {
            throw FloeError.validationFailed("operation must be plan, check, or installOrUpdate")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let hostID = args.hostID.flatMap(UUID.init(uuidString:))
        let operation = args.operation ?? (args.apply == true ? "installOrUpdate" : "plan")
        guard operation != "plan" else {
            return Self.output(
                "status=planOnly version=\(RemoteAgentPayload.version) bind=127.0.0.1 port=\(RemoteAgentPayload.defaultPort) transport=verifiedSSH requires=explicitUserRequest steps=installOrUpdate,createHostLocalToken,startUserService,healthCheck,rollbackOnFailure",
                code: 0
            )
        }

        let installer = RemoteAgentInstaller(service: service)
        let result = if operation == "check" {
            try await installer.check(hostID: hostID, cancellation: context.cancellation)
        } else {
            try await installer.installOrUpdate(hostID: hostID, cancellation: context.cancellation)
        }
        return Self.output(
            "operation=\(operation) targetKind=\(result.targetKind.rawValue) version=\(result.version) exitCode=\(result.exitCode) bind=127.0.0.1 port=\(RemoteAgentPayload.defaultPort) transport=verifiedSSH\n\(result.output)",
            code: result.exitCode
        )
    }

    private static func output(_ text: String, code: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: code)
    }
}
