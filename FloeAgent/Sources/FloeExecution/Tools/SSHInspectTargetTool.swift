import Foundation
import Crypto
import FloeCore
import FloeTools

/// Read-only target discovery for SSH strategy selection.
public struct SSHInspectTargetTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String?
        public init(hostID: String? = nil) { self.hostID = hostID }
    }

    public static let name = "ssh.inspectTarget"
    public static let toolDescription =
        "Classify a paired SSH target using read-only probes. Returns Linux/macOS/Windows/networkDevice/NAS/OpenWrt/unknown, vendor, OS evidence, container runtime and confidence. Always use this before vendor-specific commands or environment setup."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string","description":"Optional paired host UUID; omitted uses default"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: SSHCommandService
    public init(service: SSHCommandService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        if let hostID = args.hostID, UUID(uuidString: hostID) == nil {
            throw FloeError.validationFailed("hostID must be a UUID when provided")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let inspection = try await service.inspectTarget(
            hostID: args.hostID.flatMap(UUID.init(uuidString:)),
            cancellation: context.cancellation
        )
        let data = try JSONEncoder().encode(inspection)
        let text = String(decoding: data, as: UTF8.self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: 0)
    }
}
