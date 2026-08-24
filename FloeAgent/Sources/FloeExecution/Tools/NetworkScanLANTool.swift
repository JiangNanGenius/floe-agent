// FloeExecution — network.scanLAN tool for LAN device discovery.
//
// Lets the agent scan the local network for mDNS-advertised devices
// (Home Assistant, printers, smart devices). Returns a list of discovered
// devices with name, host, port, and service type.

import Foundation
import Crypto
import FloeCore
import FloeTools

public struct NetworkScanLANTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var serviceTypes: [String]?
        public var timeoutSeconds: Int?

        public init(serviceTypes: [String]? = nil, timeoutSeconds: Int? = nil) {
            self.serviceTypes = serviceTypes
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public static let name = "network.scanLAN"
    public static let toolDescription =
        "Scan the local network for mDNS-advertised devices (Home Assistant, printers, smart devices). Returns a list of discovered devices with name, host, port, and service type."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "serviceTypes": {"type": "array", "items": {"type": "string"}, "description": "mDNS service types to scan (default: common smart-home types)"},
        "timeoutSeconds": {"type": "integer", "description": "Scan timeout in seconds (default 5, max 30)"}
      },
      "required": [],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: LANDiscoveryService

    public init(service: LANDiscoveryService = LANDiscoveryService()) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        if let timeout = args.timeoutSeconds {
            guard timeout >= 1 && timeout <= 30 else {
                throw FloeError.validationFailed("timeoutSeconds must be between 1 and 30")
            }
        }
        _ = try LANDiscoveryService.normalizedServiceTypes(args.serviceTypes)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        let timeout = min(max(args.timeoutSeconds ?? 5, 1), 30)
        let types = try LANDiscoveryService.normalizedServiceTypes(args.serviceTypes)
        do {
            let devices = try await service.discover(serviceTypes: types, timeoutSeconds: timeout)
            let summary: String
            if devices.isEmpty {
                summary = "未发现局域网设备"
            } else {
                summary = "发现 \(devices.count) 个设备：\n" + devices.map {
                    "- \($0.name) (\($0.serviceType)) @ \($0.host)"
                }.joined(separator: "\n")
            }
            return Self.output(summary, exitStatus: 0)
        } catch {
            return Self.output("扫描失败：\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
