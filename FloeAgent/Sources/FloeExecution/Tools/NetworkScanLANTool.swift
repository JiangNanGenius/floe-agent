// FloeExecution — network.scanLAN tool for LAN device discovery.
//
// Runs the shared bounded discovery engine (FloeToolboxDiagnostics
// LANDiscoveryEngine) over the app-declared Bonjour scope, resolves
// advertised services to IP/port where DNS-SD actually returns an answer and
// reports unresolved services as browse-only. Empty results, blocked browsing
// and out-of-scope requests stay distinct (RQ33).

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeToolboxDiagnostics

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
        "Browse the current local network (Wi-Fi or wired Ethernet) for the app-declared Bonjour service types and resolve advertised services to address/port where DNS-SD answers. Omit serviceTypes to scan the whole declared scope (common smart-home, printer/scan, AV/casting, computer/file-share and web services). Resolved devices show host, port and verified addresses; browse-only devices show service type with 'address not resolved' — the tool never reports a fabricated IP or port. An empty list means no advertising services were found in scope (silent devices need a manual target check); blocked browsing or missing local-network permission returns an explanatory failure instead."
    public static let parametersJSON: String = {
        let enumList = LANDiscoveryScope.declaredBonjourTypes.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "type": "object",
          "properties": {
            "serviceTypes": {"type": "array", "items": {"type": "string", "enum": [\(enumList)]}, "description": "Bonjour service types to browse (default: the whole declared scope). Any type outside this enum is rejected instead of silently returning nothing."},
            "timeoutSeconds": {"type": "integer", "description": "Total budget in seconds for browsing plus bounded address resolution (default 8, max 30). Larger budgets find slower advertisers."}
          },
          "required": [],
          "additionalProperties": false
        }
        """
    }()
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

        let timeout = min(max(args.timeoutSeconds ?? 8, 1), 30)
        let types = try LANDiscoveryService.normalizedServiceTypes(args.serviceTypes)
        do {
            let devices = try await service.discover(serviceTypes: types, timeoutSeconds: timeout)
            try context.cancellation.throwIfCancelled()
            let summary: String
            if devices.isEmpty {
                summary = FloeL10n.l("execution.network_scan_l_a_n_tool.no_local_network_devices_found")
                    + " — no device advertised the browsed services; devices without Bonjour broadcasts never appear here, so check a known address with network.ping/network.tcpProbe instead."
            } else {
                summary = FloeL10n.l("execution.network_scan_l_a_n_tool.found_devices", devices.count) + devices.map {
                    if $0.isAddressResolved, $0.port > 0 {
                        let extra = $0.addresses.count > 1 ? " [" + $0.addresses.dropFirst().joined(separator: ", ") + "]" : ""
                        let endpoint = $0.host.contains(":") ? "[\($0.host)]:\($0.port)" : "\($0.host):\($0.port)"
                        return "- \($0.name) (\($0.serviceType)) @ \(endpoint)\(extra)"
                    }
                    return "- \($0.name) (\($0.serviceType)) — address not resolved (browse-only)"
                }.joined(separator: "\n")
            }
            return Self.output(summary, exitStatus: 0)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            try context.cancellation.throwIfCancelled()
            return Self.output(FloeL10n.l("execution.network_scan_l_a_n_tool.scan_failed", error.localizedDescription), exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
