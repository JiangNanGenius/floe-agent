// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics — the six `network.*` AgentTools.
//
// Thin adapters over the ORIGINAL `ToolCatalog` + `ToolRunnerRegistry`:
// each tool validates model arguments into the frozen request v1, asks the
// injected `NetworkHostExecuting` seam (production: the epoch-fenced Swift
// mailbox over the Kotlin `PhoneNetworkService`), then decodes the typed
// `NetworkObservationV1` and renders a bounded summary. The runner is
// registered only when the host pump actually bound the current generation;
// `isAvailable` rides that exact state, so discovery never advertises a
// network capability it cannot run.
//
// Risk/effect metadata is deliberate and honest:
//   riskLabels = [.networkAccess]; isSideEffecting = false; readOnly;
//   requiresHostScope = false (the phone's own network stack is the target,
//   not a remote host shell); ordinary Full and Play flavors.
// Temporary-chat exclusion is enforced by the unchanged
// `TemporaryChatToolPolicy` name ceiling AND by the executor's own
// `temporaryReadOnly`/`publicWebOnly` refusal.
import Foundation
import FloeCore
import FloeTools

/// The narrow execution seam implemented by `FloeAndroidCore`'s epoch-fenced
/// mailbox bridge. Tests inject a deterministic fake; production injects the
/// live-generation executor. A false `isAvailable` hides all six tools.
public protocol NetworkHostExecuting: Sendable {
    var isAvailable: Bool { get }
    /// Returns the exact `NetworkObservationV1` JSON bytes produced by the
    /// phone. Must not synthesize or cache a measurement and must honor the
    /// tool context's ownership/cancellation fields.
    func execute(request: NetworkToolRequest, context: ToolContext) async throws -> Data
}

// MARK: - Shared runner

enum NetworkToolRun {
    static func invoke(executor: any NetworkHostExecuting,
                       request: NetworkToolRequest,
                       context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let data: Data
        do {
            data = try await executor.execute(request: request, context: context)
        } catch let error as NetworkObservationError {
            throw mapped(error)
        }
        let observation: NetworkObservationV1
        do {
            observation = try NetworkObservationV1.decode(data, expecting: request)
        } catch let error as NetworkObservationError {
            throw mapped(error)
        }
        let summary = NetworkObservationSummary.render(observation)
        let status: Int32 = {
            switch observation.status {
            case .ok, .partial: return 0
            case .permissionRequired, .unavailable, .unsupported,
                 .cancelled, .timeout, .error: return 1
            }
        }()
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: status,
            maximumSummaryCharacters: NetworkObservationSummary.maximumCharacters)
    }

    private static func mapped(_ error: NetworkObservationError) -> FloeError {
        switch error {
        case .tooLarge:
            return .validationFailed("Network observation exceeded the 256 KiB bound")
        case .missingPermissions:
            return .internalError("Network service reported permissionRequired without missing permissions")
        default:
            // Never echo attacker-influenced target text or partial payloads.
            return .internalError("Network service returned an invalid observation")
        }
    }
}

// MARK: - network.status

public struct NetworkStatusTool: AgentTool {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public struct Arguments: Decodable, Sendable {
        public init() {}
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            guard container.allKeys.isEmpty else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "network.status takes no arguments"))
            }
        }
    }

    public static let name = "network.status"
    public static let toolDescription = "Read the phone's current network state: active/default network, transport type, interface, VPN flag, validation and captive-portal state, link addresses, DNS servers and MTU. Values come from Android ConnectivityManager/LinkProperties/NetworkCapabilities; fields the OS does not expose are absent and listed in limitations."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor, request: try .status(), context: context)
    }
}

// MARK: - network.wifiScan

public struct NetworkWifiScanTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var refresh: Bool?
    }

    public static let name = "network.wifiScan"
    public static let toolDescription = "Scan or read the phone's cached Wi-Fi access points (SSID, frequency, channel, band, signal level). Android may require location permission and can throttle fresh scans; the typed result reports permissionRequired, cacheAgeMs and throttling instead of inventing rows. BSSIDs are not printed in the summary."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "refresh":{"type":"boolean","description":"Ask Android for a fresh scan instead of the cached result. Fresh scans are throttled by the OS."}
    },"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .wifiScan(refresh: args.refresh), context: context)
    }
}

// MARK: - network.dnsLookup

public struct NetworkDNSLookupTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var host: String
        public var recordType: String?
        public var timeoutMs: Int?
    }

    public static let name = "network.dnsLookup"
    public static let toolDescription = "Resolve A/AAAA records through Android's DnsResolver on the phone's actual selected network. No public resolver fallback: on API<29 TTLs are unavailable and the result says so. Use this to check what this phone resolves, not what a server-side resolver returns."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "host":{"type":"string","description":"Bare hostname or IP literal, without scheme or path"},
      "recordType":{"type":"string","enum":["A","AAAA","A_AND_AAAA"],"description":"Record type; default A_AND_AAAA"},
      "timeoutMs":{"type":"integer","minimum":500,"maximum":30000,"description":"Bound in milliseconds; clamped to 500-30000"}
    },"required":["host"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        let host = try NetworkToolValidation.normalizedHost(args.host)
        try NetworkToolValidation.validateDiagnosticTarget(host: host)
        _ = try NetworkToolValidation.recordType(args.recordType)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .dnsLookup(host: args.host, recordType: args.recordType,
                                    timeoutMs: args.timeoutMs),
            context: context)
    }
}

// MARK: - network.ping

public struct NetworkPingTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var host: String
        public var count: Int?
        public var timeoutMs: Int?
    }

    public static let name = "network.ping"
    public static let toolDescription = "Measure reachability with unprivileged ICMP (datagram) pings on the phone's actual network. If the OS denies ICMP datagrams the result is typed unsupported; TCP connect is never presented as ping. Bounded to 10 pings and 30 seconds."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "host":{"type":"string","description":"Bare hostname or IP literal, without scheme or path"},
      "count":{"type":"integer","minimum":1,"maximum":10,"description":"Number of echo requests; default 4, clamped to 1-10"},
      "timeoutMs":{"type":"integer","minimum":500,"maximum":30000,"description":"Per-probe bound in milliseconds; clamped to 500-30000"}
    },"required":["host"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        let host = try NetworkToolValidation.normalizedHost(args.host)
        try NetworkToolValidation.validateDiagnosticTarget(host: host)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .ping(host: args.host, count: args.count,
                               timeoutMs: args.timeoutMs),
            context: context)
    }
}

// MARK: - network.tcpProbe

public struct NetworkTCPProbeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var host: String
        public var port: Int
        public var timeoutMs: Int?
    }

    public static let name = "network.tcpProbe"
    public static let toolDescription = "Open a bounded TCP connection from the phone's selected network to host:port (IPv4 or IPv6), report connect success and latency, then close it. No shell, root or host fallback. Use this for service reachability; use network.http for HTTP facts."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "host":{"type":"string","description":"Bare hostname or IP literal, without scheme or path"},
      "port":{"type":"integer","minimum":1,"maximum":65535,"description":"TCP port to connect to"},
      "timeoutMs":{"type":"integer","minimum":500,"maximum":30000,"description":"Connect bound in milliseconds; clamped to 500-30000"}
    },"required":["host","port"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        let host = try NetworkToolValidation.normalizedHost(args.host)
        try NetworkToolValidation.validateDiagnosticTarget(host: host)
        _ = try NetworkToolValidation.normalizedPort(args.port)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .tcpProbe(host: args.host, port: args.port,
                                   timeoutMs: args.timeoutMs),
            context: context)
    }
}

// MARK: - network.http

public struct NetworkHTTPTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var url: String
        public var timeoutMs: Int?
        public var maxRedirects: Int?
    }

    public static let name = "network.http"
    public static let toolDescription = "Issue a bounded HTTPS GET through Android's platform-default-trust HttpsURLConnection on the phone's selected network; report status, redirects (revalidated per hop), protocol/cipher and body size only. Cleartext HTTP returns typed unsupported. Cookies and auth headers are never sent. Use web.fetch instead when page content is the goal."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "url":{"type":"string","description":"Absolute HTTPS URL; cleartext HTTP is reported as typed unsupported"},
      "timeoutMs":{"type":"integer","minimum":500,"maximum":30000,"description":"Request bound in milliseconds; clamped to 500-30000"},
      "maxRedirects":{"type":"integer","minimum":0,"maximum":10,"description":"Maximum revalidated redirects; default 5, clamped to 0-10"}
    },"required":["url"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        _ = try NetworkToolValidation.normalizedURL(args.url)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .http(url: args.url, timeoutMs: args.timeoutMs,
                               maxRedirects: args.maxRedirects),
            context: context)
    }
}

// MARK: - Registration

/// Registers all six runners (and their catalog descriptors). Idempotent:
/// `ToolRunnerRegistry.register` replaces by name. Called by the trusted
/// `floe_network_diag_bind` export after the current epoch actually bound.
@discardableResult
public func registerNetworkTools(
    executor: any NetworkHostExecuting,
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
    add(NetworkStatusTool.self) { NetworkStatusTool(executor: executor) }
    add(NetworkWifiScanTool.self) { NetworkWifiScanTool(executor: executor) }
    add(NetworkDNSLookupTool.self) { NetworkDNSLookupTool(executor: executor) }
    add(NetworkPingTool.self) { NetworkPingTool(executor: executor) }
    add(NetworkTCPProbeTool.self) { NetworkTCPProbeTool(executor: executor) }
    add(NetworkHTTPTool.self) { NetworkHTTPTool(executor: executor) }
    return names
}

/// Exact-name removal for tests/diagnostics. Production retirement rides the
/// executor's `isAvailable` gate (the mailbox's exact-epoch bound state).
public func unregisterNetworkTools(registry: ToolRunnerRegistry = .shared) {
    let names = Set(NetworkToolMethod.allCases.map(\.rawValue))
    registry.unregister { names.contains($0) }
}

/// The closed descriptor name set, useful for readiness/capability reporting.
public enum NetworkToolNames {
    public static let all: [String] = NetworkToolMethod.allCases.map(\.rawValue)
}
