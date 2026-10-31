// SPDX-License-Identifier: MPL-2.0
//
// G07.3B offline capture analysis and Wi-Fi coverage — two read-only Agent
// tools over saved, opaque App artifacts.
//
// `network.pcapAnalyze` and `network.coverageSummary` never accept a file
// path, URI, raw bytes or a scan request. They accept a UUID minted by the
// App UI plus a bounded filter object. The host returns a <= 32 KiB redacted
// projection so the shared 64 KiB bridge frame keeps real headroom.
import Foundation
import FloeCore
import FloeTools

public enum NetworkArtifactToolMethod: String, Sendable, CaseIterable {
    case pcapAnalyze = "network.pcapAnalyze"
    case coverageSummary = "network.coverageSummary"
}

public enum NetworkArtifactLimits {
    public static let maximumRequestBytes = 8 * 1024
    public static let maximumReplyBytes = 32 * 1024
    public static let maximumFilterProtocols = 4
    public static let maximumFilterServices = 2
    public static let maximumAddressCharacters = 64
    public static let maximumSummaryCharacters = 12_000
    public static let maximumAnalysisIDCharacters = 36
}

public enum NetworkArtifactProtocolFilter: String, Sendable, CaseIterable {
    case tcp, udp, icmp, icmpv6
}

public enum NetworkArtifactServiceFilter: String, Sendable, CaseIterable {
    case dns, http
}

/// Closed filter grammar. Values are validated before any host submission;
/// the host re-validates the same shape independently.
public struct NetworkArtifactFilters: Sendable, Equatable {
    public var protocols: [String]?
    public var services: [String]?
    public var address: String?
    public var port: Int?
    public var startEpochMillis: Int64?
    public var endEpochMillis: Int64?

    public init(protocols: [String]? = nil,
                services: [String]? = nil,
                address: String? = nil,
                port: Int? = nil,
                startEpochMillis: Int64? = nil,
                endEpochMillis: Int64? = nil) {
        self.protocols = protocols
        self.services = services
        self.address = address
        self.port = port
        self.startEpochMillis = startEpochMillis
        self.endEpochMillis = endEpochMillis
    }

    /// Returns a canonical (deduplicated, sorted) filter or throws.
    public func validated() throws -> NetworkArtifactFilters {
        var normalized = self
        if let protocols {
            let values = Array(Set(protocols.map { $0.lowercased() })).sorted()
            guard !values.isEmpty,
                  values.count <= NetworkArtifactLimits.maximumFilterProtocols,
                  values.allSatisfy({ NetworkArtifactProtocolFilter(rawValue: $0) != nil })
            else {
                throw FloeError.validationFailed(
                    "protocols must be 1-4 of tcp, udp, icmp, icmpv6")
            }
            normalized.protocols = values
        }
        if let services {
            let values = Array(Set(services.map { $0.lowercased() })).sorted()
            guard !values.isEmpty,
                  values.count <= NetworkArtifactLimits.maximumFilterServices,
                  values.allSatisfy({ NetworkArtifactServiceFilter(rawValue: $0) != nil })
            else {
                throw FloeError.validationFailed("services must be dns, http")
            }
            normalized.services = values
        }
        if let address {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= NetworkArtifactLimits.maximumAddressCharacters,
                  trimmed == address,
                  !trimmed.contains(where: { $0.isWhitespace || "/@?#".contains($0) })
            else {
                throw FloeError.validationFailed(
                    "address must be a bounded bare address without whitespace or URL syntax")
            }
            normalized.address = trimmed
        }
        if let port {
            guard (1...65_535).contains(port) else {
                throw FloeError.validationFailed("port must be 1-65535")
            }
        }
        if let startEpochMillis, startEpochMillis < 0 {
            throw FloeError.validationFailed("startEpochMillis must be non-negative")
        }
        if let endEpochMillis, endEpochMillis < 0 {
            throw FloeError.validationFailed("endEpochMillis must be non-negative")
        }
        if let start = startEpochMillis, let end = endEpochMillis, start > end {
            throw FloeError.validationFailed("startEpochMillis must not be after endEpochMillis")
        }
        return normalized
    }

    func argumentObject() -> [String: Any] {
        var value: [String: Any] = [:]
        if let protocols { value["protocols"] = protocols }
        if let services { value["services"] = services }
        if let address { value["address"] = address }
        if let port { value["port"] = port }
        if let startEpochMillis { value["startEpochMillis"] = startEpochMillis }
        if let endEpochMillis { value["endEpochMillis"] = endEpochMillis }
        return value
    }
}

public struct NetworkArtifactToolRequest: Sendable, Equatable {
    public let operationID: UUID
    public let method: NetworkArtifactToolMethod
    public let argumentsJSON: Data
    public let requestJSON: Data

    public static func pcapAnalyze(
        analysisID: UUID,
        filters: NetworkArtifactFilters? = nil,
        operationID: UUID = UUID()
    ) throws -> NetworkArtifactToolRequest {
        var arguments: [String: Any] = ["analysisID": analysisID.uuidString]
        if let filters {
            arguments["filters"] = try filters.validated().argumentObject()
        }
        return try make(method: .pcapAnalyze, operationID: operationID, arguments: arguments)
    }

    public static func coverageSummary(
        sessionID: UUID,
        operationID: UUID = UUID()
    ) throws -> NetworkArtifactToolRequest {
        try make(method: .coverageSummary, operationID: operationID,
                 arguments: ["sessionID": sessionID.uuidString])
    }

    private static func make(
        method: NetworkArtifactToolMethod,
        operationID: UUID,
        arguments: [String: Any]
    ) throws -> NetworkArtifactToolRequest {
        let argumentsData = try JSONSerialization.data(withJSONObject: arguments,
                                                       options: [.sortedKeys])
        guard let argumentsObject = try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any],
              JSONSerialization.isValidJSONObject(argumentsObject) else {
            throw FloeError.validationFailed("Artifact arguments are invalid")
        }
        let envelope: [String: Any] = [
            "version": 1,
            "operationID": operationID.uuidString,
            "method": method.rawValue,
            "arguments": argumentsObject,
        ]
        let request = try JSONSerialization.data(withJSONObject: envelope,
                                                 options: [.sortedKeys])
        guard request.count <= NetworkArtifactLimits.maximumRequestBytes else {
            throw FloeError.validationFailed("Artifact request exceeds 8 KiB")
        }
        return NetworkArtifactToolRequest(
            operationID: operationID, method: method,
            argumentsJSON: argumentsData, requestJSON: request)
    }
}

/// The execution seam implemented by FloeAndroidCore's epoch-fenced mailbox.
public protocol NetworkArtifactHostExecuting: Sendable {
    var isAvailable: Bool { get }
    func execute(request: NetworkArtifactToolRequest, context: ToolContext) async throws -> Data
}

enum NetworkArtifactToolRun {
    static func invoke(executor: any NetworkArtifactHostExecuting,
                       request: NetworkArtifactToolRequest,
                       context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let data: Data
        do {
            data = try await executor.execute(request: request, context: context)
        } catch let error as FloeError {
            throw error
        } catch {
            throw FloeError.internalError("Artifact host failed")
        }
        guard data.count <= NetworkArtifactLimits.maximumReplyBytes else {
            throw FloeError.validationFailed("Artifact reply exceeded 32 KiB")
        }
        let reply = try NetworkArtifactReply.decode(data, method: request.method)
        let summary = NetworkArtifactSummary.render(reply)
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: reply.status == "ok" || reply.status == "partial" ? 0 : 1,
            maximumSummaryCharacters: NetworkArtifactLimits.maximumSummaryCharacters)
    }
}

// MARK: - Reply

struct NetworkArtifactReply {
    let method: NetworkArtifactToolMethod
    let status: String
    let root: [String: Any]

    static func decode(_ data: Data, method: NetworkArtifactToolMethod) throws -> NetworkArtifactReply {
        guard data.count <= NetworkArtifactLimits.maximumReplyBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 1,
              root["source"] as? String == "phone",
              let status = root["status"] as? String,
              ["ok", "partial", "failed", "unavailable"].contains(status)
        else {
            throw FloeError.internalError("Artifact host returned an invalid bounded reply")
        }
        let schema = root["schema"] as? String
        switch method {
        case .pcapAnalyze:
            guard schema == "floe.pcap-tool-summary.v1" else {
                throw FloeError.internalError("Artifact host returned the wrong reply shape")
            }
        case .coverageSummary:
            guard schema == "floe.coverage-tool-summary.v1" else {
                throw FloeError.internalError("Artifact host returned the wrong reply shape")
            }
        }
        return NetworkArtifactReply(method: method, status: status, root: root)
    }
}

enum NetworkArtifactSummary {
    static func render(_ reply: NetworkArtifactReply) -> String {
        let text: String
        switch reply.method {
        case .pcapAnalyze: text = pcap(reply.root)
        case .coverageSummary: text = coverage(reply.root)
        }
        if text.count <= NetworkArtifactLimits.maximumSummaryCharacters { return text }
        return String(text.prefix(NetworkArtifactLimits.maximumSummaryCharacters))
    }

    private static func pcap(_ root: [String: Any]) -> String {
        var lines: [String] = []
        let status = root["status"] as? String ?? "unavailable"
        let format = root["format"] as? String ?? "unknown"
        let totals = root["totals"] as? [String: Any] ?? [:]
        let matched = root["matched"] as? [String: Any] ?? [:]
        lines.append("Capture analysis (\(status), \(format))")
        lines.append("Packets: \(number(totals["packets"])) · bytes: \(number(totals["bytes"])) · flows: \(number(totals["flows"])) retained: \(number(totals["retainedFlows"]))")
        if totals["startEpochMillis"] is Int64 || totals["startEpochMillis"] is Int {
            lines.append("Time span: \(number(totals["startEpochMillis"])) to \(number(totals["endEpochMillis"])) (epoch ms)")
        }
        lines.append("Filters match: \(number(matched["flows"])) flows · \(number(matched["flowPackets"])) packets · \(number(matched["flowBytes"])) bytes")
        if let protocols = root["protocols"] as? [[String: Any]], !protocols.isEmpty {
            let text = protocols.prefix(8).map {
                "\($0["protocol"] as? String ?? "?"): \(number($0["packets"])) pkts/\(number($0["bytes"])) B"
            }.joined(separator: ", ")
            lines.append("Protocols: \(text)")
        }
        if let flows = root["flows"] as? [[String: Any]], !flows.isEmpty {
            lines.append("Top flows:")
            for flow in flows.prefix(20) {
                let src = flow["src"] as? [String: Any] ?? [:]
                let dst = flow["dst"] as? [String: Any] ?? [:]
                let source = "\(src["address"] as? String ?? "?")\(port(src["port"]))"
                let destination = "\(dst["address"] as? String ?? "?")\(port(dst["port"]))"
                lines.append("- \(flow["protocol"] as? String ?? "?") \(source) → \(destination) · \(number(flow["packets"])) pkts / \(number(flow["bytes"])) B")
            }
        }
        if let dns = root["dns"] as? [[String: Any]], !dns.isEmpty {
            lines.append("DNS records: \(dns.count) shown")
            for record in dns.prefix(8) {
                lines.append("- \(record["direction"] as? String ?? "?") \(record["name"] as? String ?? "?") \(record["recordType"] as? String ?? "?")")
            }
        }
        if let http = root["http"] as? [[String: Any]], !http.isEmpty {
            lines.append("HTTP records: \(http.count) shown")
            for record in http.prefix(8) {
                lines.append("- \(record["direction"] as? String ?? "?") \(record["methodOrStatus"] as? String ?? "?")")
            }
        }
        if let limitations = root["limitations"] as? [String], !limitations.isEmpty {
            lines.append("Limitations:")
            for limitation in limitations.prefix(8) { lines.append("- \(limitation)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func coverage(_ root: [String: Any]) -> String {
        var lines: [String] = []
        let status = root["status"] as? String ?? "unavailable"
        let aggregate = root["aggregate"] as? [String: Any] ?? [:]
        lines.append("Wi-Fi coverage (\(status)): \(root["name"] as? String ?? "session")")
        lines.append("Points: \(number(root["pointCount"])) · grid sampled: \(number(aggregate["estimatedCoveragePercent"]))% · unsampled cells: \(number(aggregate["unsampledCells"]))")
        lines.append("RSSI: min \(number(aggregate["rssiMin"])) / avg \(decimal(aggregate["rssiAverage"])) / max \(number(aggregate["rssiMax"])) dBm")
        lines.append("Stale: \(number(aggregate["staleCount"])) · permission issues: \(number(aggregate["permissionRequiredCount"])) · cached: \(number(aggregate["cachedScanCount"]))")
        if let locations = root["namedLocations"] as? [String], !locations.isEmpty {
            lines.append("Locations: \(locations.prefix(16).joined(separator: ", "))")
        }
        if let points = root["points"] as? [[String: Any]], !points.isEmpty {
            lines.append("Samples:")
            for point in points.prefix(30) {
                let label = point["label"] as? String ?? "(unnamed)"
                lines.append("- \(label) · \(number(point["rssiDbm"])) dBm · \(point["level"] as? String ?? "?") · ch \(number(point["channel"])) · stale \(point["stale"] as? Bool == true)")
            }
        }
        if let limitations = root["limitations"] as? [String], !limitations.isEmpty {
            lines.append("Limitations:")
            for limitation in limitations.prefix(8) { lines.append("- \(limitation)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func number(_ value: Any?) -> String {
        if let int = value as? Int { return String(int) }
        if let int = value as? Int64 { return String(int) }
        if let double = value as? Double {
            return String(format: "%.1f", double)
        }
        return "—"
    }

    private static func decimal(_ value: Any?) -> String {
        if let double = value as? Double { return String(format: "%.1f", double) }
        return number(value)
    }

    private static func port(_ value: Any?) -> String {
        if let int = value as? Int { return ":\(int)" }
        if let int = value as? Int64 { return ":\(int)" }
        return ""
    }
}

// MARK: - Tools

public struct NetworkPCAPAnalyzeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public struct Filters: Decodable, Sendable {
            public var protocols: [String]?
            public var services: [String]?
            public var address: String?
            public var port: Int?
            public var startEpochMillis: Int64?
            public var endEpochMillis: Int64?
        }
        public var analysisID: String
        public var filters: Filters?
    }

    public static let name = NetworkArtifactToolMethod.pcapAnalyze.rawValue
    public static let toolDescription = "Read the bounded, already-saved summary of a PCAP/PCAPNG capture analysed on this device. Arguments are an opaque analysisID UUID (minted by the Network workbench) plus optional protocol/service/time/address/port filters. Raw captures, arbitrary paths, URIs and uploads are never accepted. Results are redacted and may be partial/truncated; TLS payloads and reassembly are unavailable."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "analysisID":{"type":"string","format":"uuid","description":"Opaque saved-analysis ID shown in the Network workbench"},
      "filters":{"type":"object","properties":{
        "protocols":{"type":"array","items":{"type":"string","enum":["tcp","udp","icmp","icmpv6"]},"minItems":1,"maxItems":4},
        "services":{"type":"array","items":{"type":"string","enum":["dns","http"]},"minItems":1,"maxItems":2},
        "address":{"type":"string","description":"Bare IPv4/IPv6 address; 64 characters max"},
        "port":{"type":"integer","minimum":1,"maximum":65535},
        "startEpochMillis":{"type":"integer","minimum":0},
        "endEpochMillis":{"type":"integer","minimum":0}
      },"additionalProperties":false}
    },"required":["analysisID"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkArtifactHostExecuting
    public init(executor: any NetworkArtifactHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        _ = try request(for: args)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkArtifactToolRun.invoke(
            executor: executor, request: try request(for: args), context: context)
    }

    private func request(for args: Arguments) throws -> NetworkArtifactToolRequest {
        guard let analysisID = UUID(uuidString: args.analysisID) else {
            throw FloeError.validationFailed("analysisID must be a UUID")
        }
        let filters = args.filters.map {
            NetworkArtifactFilters(
                protocols: $0.protocols, services: $0.services, address: $0.address,
                port: $0.port, startEpochMillis: $0.startEpochMillis,
                endEpochMillis: $0.endEpochMillis)
        }
        return try .pcapAnalyze(analysisID: analysisID, filters: filters)
    }
}

public struct NetworkCoverageSummaryTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
    }

    public static let name = NetworkArtifactToolMethod.coverageSummary.rawValue
    public static let toolDescription = "Read a saved, user-sampled Wi-Fi coverage session: normalized points, best real scan RSSI, channel/band, sample age, stale/permission/cached states and an estimated grid. Arguments are an opaque sessionID UUID; no background scan, GPS, RTT ranging or synthetic RF value is performed or returned."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "sessionID":{"type":"string","format":"uuid","description":"Opaque coverage-session ID shown in the Network workbench"}
    },"required":["sessionID"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkArtifactHostExecuting
    public init(executor: any NetworkArtifactHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        _ = try request(for: args)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkArtifactToolRun.invoke(
            executor: executor, request: try request(for: args), context: context)
    }

    private func request(for args: Arguments) throws -> NetworkArtifactToolRequest {
        guard let sessionID = UUID(uuidString: args.sessionID) else {
            throw FloeError.validationFailed("sessionID must be a UUID")
        }
        return try .coverageSummary(sessionID: sessionID)
    }
}

// MARK: - Registration

@discardableResult
public func registerNetworkArtifactTools(
    executor: any NetworkArtifactHostExecuting,
    registry: ToolRunnerRegistry = .shared
) -> [String] {
    var names: [String] = []
    func add<T: AgentTool>(_ type: T.Type, _ make: @escaping @Sendable () -> T) {
        ToolCatalog.register(type)
        var runner = AnyAgentTool(make())
        runner.isAvailable = { executor.isAvailable }
        registry.register(runner)
        names.append(T.name)
    }
    add(NetworkPCAPAnalyzeTool.self) { NetworkPCAPAnalyzeTool(executor: executor) }
    add(NetworkCoverageSummaryTool.self) { NetworkCoverageSummaryTool(executor: executor) }
    return names
}

public func unregisterNetworkArtifactTools(registry: ToolRunnerRegistry = .shared) {
    let names = Set(NetworkArtifactToolMethod.allCases.map(\.rawValue))
    registry.unregister { names.contains($0) }
}

public enum NetworkArtifactToolNames {
    public static let all: [String] = NetworkArtifactToolMethod.allCases.map(\.rawValue)
}
