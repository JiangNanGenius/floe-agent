// SPDX-License-Identifier: MPL-2.0
//
// G07.1/G07.2 network diagnostics — the eight `network.*` AgentTools.
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
/// live-generation executor. A false `isAvailable` hides every network tool.
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

// MARK: - network.lanDiscover

public struct NetworkLANDiscoverTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var serviceTypes: [String]?
        public var subnetCidr: String?
        public var ports: [Int]?
        public var discoveryDurationMs: Int?
        public var includeAttributes: Bool?
        public var tcpConnectTimeoutMs: Int?
        public var tcpConcurrency: Int?
        public var timeoutMs: Int?
    }

    public static let name = "network.lanDiscover"
    public static let toolDescription = "Discover devices and services on the phone's current private LAN: bounded DNS-SD/mDNS browsing for explicit service types plus an optional RFC1918 TCP connect scan (hosts x ports). A device that is asleep, silent or unadvertised is not evidence it is absent; open ports come only from real TCP handshakes and no banner or payload is read. API 37+ needs the local-network permission and Android below 33 reports mDNS as typed unsupported while TCP subnet discovery remains available."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "serviceTypes":{"type":"array","items":{"type":"string","pattern":"^_[a-z0-9](?:[a-z0-9-]{0,13}[a-z0-9])?\\._(tcp|udp)$"},"minItems":1,"maxItems":8,"description":"Explicit DNS-SD types such as _http._tcp or _ipp._tcp; lowercased and deduplicated"},
      "subnetCidr":{"type":"string","description":"RFC1918 private IPv4 subnet prefix /24-/30 with zero host bits, e.g. 192.168.1.0/24; requires ports"},
      "ports":{"type":"array","items":{"type":"integer","minimum":1,"maximum":65535},"minItems":1,"maxItems":8,"description":"TCP ports for the subnet scan; required with subnetCidr and bounded to 1024 total attempts"},
      "discoveryDurationMs":{"type":"integer","minimum":500,"maximum":15000,"description":"mDNS browse window; default 4000, clamped to 500-15000"},
      "includeAttributes":{"type":"boolean","description":"Include bounded DNS-SD TXT attributes in the full observation; default false"},
      "tcpConnectTimeoutMs":{"type":"integer","minimum":100,"maximum":2000,"description":"Per-connect bound; default 500, clamped to 100-2000"},
      "tcpConcurrency":{"type":"integer","minimum":1,"maximum":32,"description":"Concurrent TCP connects; default 16, clamped to 1-32"},
      "timeoutMs":{"type":"integer","minimum":500,"maximum":30000,"description":"Whole-operation bound; default 20000 and raised when needed to cover the discovery window"}
    },"anyOf":[{"required":["serviceTypes"]},{"required":["subnetCidr"]}],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        let types = try NetworkToolValidation.serviceTypes(args.serviceTypes)
        let subnet = try args.subnetCidr.map {
            try NetworkToolValidation.privateSubnet($0)
        }
        guard !types.isEmpty || subnet != nil else {
            throw FloeError.validationFailed(
                "network.lanDiscover requires at least one serviceType or a private subnetCidr")
        }
        if let subnet {
            let ports = try NetworkToolValidation.lanPorts(args.ports)
            try NetworkToolValidation.checkLANAttemptBudget(
                subnet: subnet, portCount: ports.count)
        } else if args.ports != nil {
            throw FloeError.validationFailed(
                "ports are only valid together with subnetCidr")
        }
        _ = try NetworkToolValidation.lanTimeout(
            requested: args.timeoutMs,
            discoveryDurationMs: NetworkToolValidation.clamp(
                args.discoveryDurationMs,
                defaultValue: NetworkToolLimits.defaultLANDiscoveryMs,
                minimum: NetworkToolLimits.minimumLANDiscoveryMs,
                maximum: NetworkToolLimits.maximumLANDiscoveryMs),
            hasMDNS: !types.isEmpty, hasTCP: subnet != nil)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .lanDiscover(
                serviceTypes: args.serviceTypes,
                subnetCidr: args.subnetCidr,
                ports: args.ports,
                discoveryDurationMs: args.discoveryDurationMs,
                includeAttributes: args.includeAttributes,
                tcpConnectTimeoutMs: args.tcpConnectTimeoutMs,
                tcpConcurrency: args.tcpConcurrency,
                timeoutMs: args.timeoutMs),
            context: context)
    }
}

// MARK: - network.speedTest

public struct NetworkSpeedTestTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var direction: String?
        public var downloadUrl: String?
        public var uploadUrl: String?
        public var maxBytesPerDirection: Int?
        public var durationBudgetMs: Int?
        public var warmupBytes: Int?
        public var allowMetered: Bool?
        public var timeoutMs: Int?
    }

    public static let name = "network.speedTest"
    public static let toolDescription = "Measure actual point-in-time throughput to explicit HTTPS endpoints: download reads a bounded response body, upload POSTs a bounded synthetic pattern (never a file, cookie or auth header) only when direction includes upload. Budgets are per direction and strict (default 8 MiB and 10 s per direction); the tool reports actual payload bytes, monotonic elapsed time and a rate only when the interval is usable. One transfer is not a broadband ceiling, and upload bytes prove only client TLS stream acceptance, not server receipt. Because an upload can change server state, this tool is conservatively treated as mutating. Redirects are not followed, metered networks are refused unless allowed, and a local/.local endpoint may report permissionRequired for the existing local-network grant."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "direction":{"type":"string","enum":["download","upload","downloadAndUpload"],"description":"Transfer direction; default download"},
      "downloadUrl":{"type":"string","description":"Explicit HTTPS payload URL for download; required for download and downloadAndUpload"},
      "uploadUrl":{"type":"string","description":"Explicit HTTPS endpoint for the synthetic upload; required for upload and downloadAndUpload"},
      "maxBytesPerDirection":{"type":"integer","minimum":65536,"maximum":33554432,"description":"Strict per-direction byte cap; default 8388608"},
      "durationBudgetMs":{"type":"integer","minimum":1000,"maximum":15000,"description":"Strict per-direction time budget; default 10000"},
      "warmupBytes":{"type":"integer","minimum":0,"maximum":262144,"description":"Excluded warmup bytes per direction; default 0 and must be below the byte cap"},
      "allowMetered":{"type":"boolean","description":"Allow transfer on a metered network; default false (refused before connecting)"},
      "timeoutMs":{"type":"integer","minimum":500,"maximum":30000,"description":"Whole-operation deadline; default 30000 and raised to cover the strict budgets"}
    },"additionalProperties":false}
    """#
    // A speed test may POST synthetic bytes to an explicit endpoint. A fixed
    // payload can still change server state, so this combined tool is
    // conservatively mutating/side-effecting even for download-only calls.
    // `requiresHostScope` stays false: the endpoint is opaque argument data,
    // not a host-scope grant, and the phone's network stack is the executor.
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .modifiesRemoteSystem]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let executor: any NetworkHostExecuting
    public init(executor: any NetworkHostExecuting) { self.executor = executor }

    public func validate(_ args: Arguments) throws {
        let direction = try NetworkToolValidation.speedDirection(args.direction)
        let download = try args.downloadUrl.map {
            try NetworkToolValidation.normalizedSpeedURL($0)
        }
        let upload = try args.uploadUrl.map {
            try NetworkToolValidation.normalizedSpeedURL($0)
        }
        if direction.includesDownload, download == nil {
            throw FloeError.validationFailed(
                "downloadUrl is required for direction \(direction.rawValue)")
        }
        if direction.includesUpload, upload == nil {
            throw FloeError.validationFailed(
                "uploadUrl is required for direction \(direction.rawValue)")
        }
        let maxBytes = try NetworkToolValidation.strict(
            args.maxBytesPerDirection, name: "maxBytesPerDirection",
            defaultValue: NetworkToolLimits.defaultSpeedBytes,
            range: NetworkToolLimits.minimumSpeedBytes...NetworkToolLimits.maximumSpeedBytes)
        let duration = try NetworkToolValidation.strict(
            args.durationBudgetMs, name: "durationBudgetMs",
            defaultValue: NetworkToolLimits.defaultSpeedDurationMs,
            range: NetworkToolLimits.minimumSpeedDurationMs...NetworkToolLimits.maximumSpeedDurationMs)
        let warmup = try NetworkToolValidation.strict(
            args.warmupBytes, name: "warmupBytes", defaultValue: 0,
            range: 0...NetworkToolLimits.maximumWarmupBytes)
        guard warmup < maxBytes else {
            throw FloeError.validationFailed(
                "warmupBytes must be less than maxBytesPerDirection")
        }
        _ = try NetworkToolValidation.speedTimeout(
            requested: args.timeoutMs, durationBudgetMs: duration,
            directionCount: direction.directionCount)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await NetworkToolRun.invoke(
            executor: executor,
            request: try .speedTest(
                direction: try NetworkToolValidation.speedDirection(args.direction),
                downloadURL: args.downloadUrl,
                uploadURL: args.uploadUrl,
                maxBytesPerDirection: args.maxBytesPerDirection,
                durationBudgetMs: args.durationBudgetMs,
                warmupBytes: args.warmupBytes,
                allowMetered: args.allowMetered,
                timeoutMs: args.timeoutMs),
            context: context)
    }
}

// MARK: - Registration

/// Registers all eight runners (and their catalog descriptors). Idempotent:
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
    add(NetworkLANDiscoverTool.self) { NetworkLANDiscoverTool(executor: executor) }
    add(NetworkSpeedTestTool.self) { NetworkSpeedTestTool(executor: executor) }
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
