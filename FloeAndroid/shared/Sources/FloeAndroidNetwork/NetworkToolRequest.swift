// SPDX-License-Identifier: MPL-2.0
//
// G07.1/G07.2 network diagnostics — the exact request v1 built for
// `PhoneNetworkService.execute(String)` and the tool-side argument guards.
//
// Frozen input contract (platform01):
//   {version:1, operationID:UUID, method:<exact tool name>, arguments:{...}}
//   network.status{}; network.wifiScan{refresh?:bool=false};
//   network.dnsLookup{host,recordType?=A_AND_AAAA,timeoutMs?=5000};
//   network.ping{host,count?=4,timeoutMs?=5000};
//   network.tcpProbe{host,port,timeoutMs?=5000};
//   network.http{url,timeoutMs?=10000,maxRedirects?=5};
//   network.lanDiscover{serviceTypes?,subnetCidr?,ports?,discoveryDurationMs?,
//     includeAttributes?,tcpConnectTimeoutMs?,tcpConcurrency?,timeoutMs?};
//   network.speedTest{direction?,downloadUrl?,uploadUrl?,maxBytesPerDirection?,
//     durationBudgetMs?,warmupBytes?,allowMetered?,timeoutMs?}.
//
// Bounds: request <= 16 KiB, observation <= 256 KiB, AP rows <= 256, ping
// count <= 10, any timeout <= 30 s. Timing/count values are CLAMPED; a host,
// port, CIDR, service type or URL that is structurally invalid is REFUSED.
// Speed byte/duration/warmup budgets are STRICT (refused, never widened).
// The service remains authoritative for DNS/routing/TLS/permission decisions.
// In particular, endpoint arguments are opaque user data: they never grant
// permission and are only host-normalized for the existing LAN broker hint.
import Foundation
import FloeCore

public enum NetworkToolLimits {
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumObservationBytes = 256 * 1024
    public static let maximumAccessPoints = 256
    public static let maximumPingCount = 10
    public static let minimumPingCount = 1
    public static let maximumTimeoutMs = 30_000
    public static let minimumTimeoutMs = 500
    public static let defaultDNSLookupTimeoutMs = 5_000
    public static let defaultPingTimeoutMs = 5_000
    public static let defaultTCPTimeoutMs = 5_000
    public static let defaultHTTPTimeoutMs = 10_000
    public static let defaultMaxRedirects = 5
    public static let maximumRedirects = 10
    public static let maximumHostBytes = 253
    public static let maximumURLBytes = 4_096

    // G07.2 LAN discovery (frozen platform01 bounds).
    public static let maximumLANServiceTypes = 8
    public static let maximumLANPorts = 8
    public static let maximumLANHosts = 254
    public static let maximumLANAttempts = 1_024
    public static let defaultLANDiscoveryMs = 4_000
    public static let minimumLANDiscoveryMs = 500
    public static let maximumLANDiscoveryMs = 15_000
    public static let defaultLANTimeoutMs = 20_000
    public static let defaultTCPConnectTimeoutMs = 500
    public static let minimumTCPConnectTimeoutMs = 100
    public static let maximumTCPConnectTimeoutMs = 2_000
    public static let defaultTCPConcurrency = 16
    public static let maximumTCPConcurrency = 32

    // G07.2 explicitly budgeted throughput diagnostics.
    public static let defaultSpeedBytes = 8_388_608
    public static let minimumSpeedBytes = 65_536
    public static let maximumSpeedBytes = 33_554_432
    public static let defaultSpeedDurationMs = 10_000
    public static let minimumSpeedDurationMs = 1_000
    public static let maximumSpeedDurationMs = 15_000
    public static let maximumWarmupBytes = 262_144
    public static let defaultSpeedTimeoutMs = 30_000
    public static let speedConnectionMarginMs = 1_500
}

public enum NetworkToolMethod: String, Sendable, CaseIterable {
    case status = "network.status"
    case wifiScan = "network.wifiScan"
    case dnsLookup = "network.dnsLookup"
    case ping = "network.ping"
    case tcpProbe = "network.tcpProbe"
    case http = "network.http"
    case lanDiscover = "network.lanDiscover"
    case speedTest = "network.speedTest"
}

/// Frozen `direction` values for `network.speedTest`.
public enum NetworkSpeedDirection: String, Sendable, CaseIterable {
    case download
    case upload
    case downloadAndUpload

    var directionCount: Int {
        switch self {
        case .download, .upload: return 1
        case .downloadAndUpload: return 2
        }
    }

    var includesDownload: Bool { self != .upload }
    var includesUpload: Bool { self != .download }
}

public struct NetworkToolRequest: Sendable, Equatable {
    public let operationID: UUID
    public let method: NetworkToolMethod
    /// Canonical, sorted-key `arguments` object only.
    public let argumentsJSON: Data
    /// The exact `{version,operationID,method,arguments}` bytes staged to the
    /// Android service. Never larger than 16 KiB.
    public let requestJSON: Data

    public static func status(operationID: UUID = UUID()) throws -> NetworkToolRequest {
        try make(method: .status, operationID: operationID, arguments: [:])
    }

    public static func wifiScan(refresh: Bool?, operationID: UUID = UUID()) throws -> NetworkToolRequest {
        try make(method: .wifiScan, operationID: operationID,
                 arguments: ["refresh": .bool(refresh ?? false)])
    }

    public static func dnsLookup(host: String, recordType: String?,
                                 timeoutMs: Int?, operationID: UUID = UUID()) throws -> NetworkToolRequest {
        let normalizedHost = try NetworkToolValidation.normalizedHost(host)
        try NetworkToolValidation.validateDiagnosticTarget(host: normalizedHost)
        let type = try NetworkToolValidation.recordType(recordType)
        let timeout = NetworkToolValidation.clampTimeout(
            timeoutMs, defaultValue: NetworkToolLimits.defaultDNSLookupTimeoutMs)
        return try make(method: .dnsLookup, operationID: operationID, arguments: [
            "host": .string(normalizedHost),
            "recordType": .string(type),
            "timeoutMs": .int(timeout),
        ])
    }

    public static func ping(host: String, count: Int?, timeoutMs: Int?,
                            operationID: UUID = UUID()) throws -> NetworkToolRequest {
        let normalizedHost = try NetworkToolValidation.normalizedHost(host)
        try NetworkToolValidation.validateDiagnosticTarget(host: normalizedHost)
        let clampedCount = NetworkToolValidation.clampPingCount(count)
        let timeout = NetworkToolValidation.clampTimeout(
            timeoutMs, defaultValue: NetworkToolLimits.defaultPingTimeoutMs)
        return try make(method: .ping, operationID: operationID, arguments: [
            "host": .string(normalizedHost),
            "count": .int(clampedCount),
            "timeoutMs": .int(timeout),
        ])
    }

    public static func tcpProbe(host: String, port: Int, timeoutMs: Int?,
                                operationID: UUID = UUID()) throws -> NetworkToolRequest {
        let normalizedHost = try NetworkToolValidation.normalizedHost(host)
        try NetworkToolValidation.validateDiagnosticTarget(host: normalizedHost)
        let normalizedPort = try NetworkToolValidation.normalizedPort(port)
        let timeout = NetworkToolValidation.clampTimeout(
            timeoutMs, defaultValue: NetworkToolLimits.defaultTCPTimeoutMs)
        return try make(method: .tcpProbe, operationID: operationID, arguments: [
            "host": .string(normalizedHost),
            "port": .int(normalizedPort),
            "timeoutMs": .int(timeout),
        ])
    }

    public static func http(url: String, timeoutMs: Int?, maxRedirects: Int?,
                            operationID: UUID = UUID()) throws -> NetworkToolRequest {
        let normalizedURL = try NetworkToolValidation.normalizedURL(url)
        let timeout = NetworkToolValidation.clampTimeout(
            timeoutMs, defaultValue: NetworkToolLimits.defaultHTTPTimeoutMs)
        let redirects = NetworkToolValidation.clampRedirects(maxRedirects)
        return try make(method: .http, operationID: operationID, arguments: [
            "url": .string(normalizedURL),
            "timeoutMs": .int(timeout),
            "maxRedirects": .int(redirects),
        ])
    }

    /// `network.lanDiscover`. At least one of serviceTypes/subnetCidr is
    /// required; ports are required exactly when subnetCidr is present.
    /// Every non-volume value below is either normalized or clamped exactly as
    /// the frozen platform parser does, so the Agent never sends a request the
    /// service would reject for a bound that could have been normalized here.
    public static func lanDiscover(serviceTypes: [String]?,
                                   subnetCidr: String?,
                                   ports: [Int]?,
                                   discoveryDurationMs: Int?,
                                   includeAttributes: Bool?,
                                   tcpConnectTimeoutMs: Int?,
                                   tcpConcurrency: Int?,
                                   timeoutMs: Int?,
                                   operationID: UUID = UUID()) throws -> NetworkToolRequest {
        let types = try NetworkToolValidation.serviceTypes(serviceTypes)
        let subnet = try subnetCidr.map { try NetworkToolValidation.privateSubnet($0) }
        guard !types.isEmpty || subnet != nil else {
            throw FloeError.validationFailed(
                "network.lanDiscover requires at least one serviceType or a private subnetCidr")
        }
        let normalizedPorts: [Int]
        if let subnet {
            normalizedPorts = try NetworkToolValidation.lanPorts(ports)
            try NetworkToolValidation.checkLANAttemptBudget(
                subnet: subnet, portCount: normalizedPorts.count)
        } else {
            guard ports == nil else {
                throw FloeError.validationFailed(
                    "ports are only valid together with subnetCidr")
            }
            normalizedPorts = []
        }
        let discovery = NetworkToolValidation.clamp(
            discoveryDurationMs,
            defaultValue: NetworkToolLimits.defaultLANDiscoveryMs,
            minimum: NetworkToolLimits.minimumLANDiscoveryMs,
            maximum: NetworkToolLimits.maximumLANDiscoveryMs)
        let timeout = try NetworkToolValidation.lanTimeout(
            requested: timeoutMs, discoveryDurationMs: discovery,
            hasMDNS: !types.isEmpty, hasTCP: subnet != nil)
        var arguments: [String: NetworkJSONValue] = [
            "serviceTypes": .array(types.map { .string($0) }),
            "discoveryDurationMs": .int(discovery),
            "includeAttributes": .bool(includeAttributes ?? false),
            "timeoutMs": .int(timeout),
        ]
        if let subnet {
            arguments["subnetCidr"] = .string(subnet.cidr)
            arguments["ports"] = .array(normalizedPorts.map { .int($0) })
            arguments["tcpConnectTimeoutMs"] = .int(NetworkToolValidation.clamp(
                tcpConnectTimeoutMs,
                defaultValue: NetworkToolLimits.defaultTCPConnectTimeoutMs,
                minimum: NetworkToolLimits.minimumTCPConnectTimeoutMs,
                maximum: NetworkToolLimits.maximumTCPConnectTimeoutMs))
            arguments["tcpConcurrency"] = .int(NetworkToolValidation.clamp(
                tcpConcurrency,
                defaultValue: NetworkToolLimits.defaultTCPConcurrency,
                minimum: 1,
                maximum: NetworkToolLimits.maximumTCPConcurrency))
        }
        return try make(method: .lanDiscover, operationID: operationID,
                        arguments: arguments)
    }

    /// `network.speedTest`. Endpoints are explicit; there is no default hosted
    /// endpoint and no implicit upload. Byte/duration/warmup budgets are
    /// strict, and an impossible timeout (budgets exceed the 30 s ceiling) is
    /// refused instead of silently widened.
    public static func speedTest(direction: NetworkSpeedDirection?,
                                 downloadURL: String?,
                                 uploadURL: String?,
                                 maxBytesPerDirection: Int?,
                                 durationBudgetMs: Int?,
                                 warmupBytes: Int?,
                                 allowMetered: Bool?,
                                 timeoutMs: Int?,
                                 operationID: UUID = UUID()) throws -> NetworkToolRequest {
        let resolvedDirection = direction ?? .download
        let download = try downloadURL.map {
            try NetworkToolValidation.normalizedSpeedURL($0)
        }
        let upload = try uploadURL.map {
            try NetworkToolValidation.normalizedSpeedURL($0)
        }
        if resolvedDirection.includesDownload, download == nil {
            throw FloeError.validationFailed(
                "downloadUrl is required for direction \(resolvedDirection.rawValue)")
        }
        if resolvedDirection.includesUpload, upload == nil {
            throw FloeError.validationFailed(
                "uploadUrl is required for direction \(resolvedDirection.rawValue)")
        }
        let maxBytes = try NetworkToolValidation.strict(
            maxBytesPerDirection,
            name: "maxBytesPerDirection",
            defaultValue: NetworkToolLimits.defaultSpeedBytes,
            range: NetworkToolLimits.minimumSpeedBytes...NetworkToolLimits.maximumSpeedBytes)
        let duration = try NetworkToolValidation.strict(
            durationBudgetMs,
            name: "durationBudgetMs",
            defaultValue: NetworkToolLimits.defaultSpeedDurationMs,
            range: NetworkToolLimits.minimumSpeedDurationMs...NetworkToolLimits.maximumSpeedDurationMs)
        let warmup = try NetworkToolValidation.strict(
            warmupBytes,
            name: "warmupBytes",
            defaultValue: 0,
            range: 0...NetworkToolLimits.maximumWarmupBytes)
        guard warmup < maxBytes else {
            throw FloeError.validationFailed(
                "warmupBytes must be less than maxBytesPerDirection")
        }
        let timeout = try NetworkToolValidation.speedTimeout(
            requested: timeoutMs, durationBudgetMs: duration,
            directionCount: resolvedDirection.directionCount)
        var arguments: [String: NetworkJSONValue] = [
            "direction": .string(resolvedDirection.rawValue),
            "maxBytesPerDirection": .int(maxBytes),
            "durationBudgetMs": .int(duration),
            "warmupBytes": .int(warmup),
            "allowMetered": .bool(allowMetered ?? false),
            "timeoutMs": .int(timeout),
        ]
        if resolvedDirection.includesDownload, let download {
            arguments["downloadUrl"] = .string(download)
        }
        if resolvedDirection.includesUpload, let upload {
            arguments["uploadUrl"] = .string(upload)
        }
        return try make(method: .speedTest, operationID: operationID,
                        arguments: arguments)
    }

    /// Shared builder. The arguments object is canonicalized so the request
    /// bytes are deterministic for the same operationID and values.
    public static func make(method: NetworkToolMethod,
                            operationID: UUID,
                            arguments: [String: NetworkJSONValue]) throws -> NetworkToolRequest {
        let argumentObject = arguments.mapValues(\.foundationObject)
        guard JSONSerialization.isValidJSONObject(argumentObject) else {
            throw FloeError.validationFailed("Network arguments are not a valid JSON object")
        }
        let argumentsData = try JSONSerialization.data(
            withJSONObject: argumentObject, options: [.sortedKeys])
        let envelope: [String: Any] = [
            "version": 1,
            "operationID": operationID.uuidString,
            "method": method.rawValue,
            "arguments": argumentObject,
        ]
        let requestData = try JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys])
        guard requestData.count <= NetworkToolLimits.maximumRequestBytes else {
            throw FloeError.validationFailed(
                "Network request exceeds 16 KiB; shorten the target or arguments")
        }
        return NetworkToolRequest(operationID: operationID, method: method,
                                  argumentsJSON: argumentsData, requestJSON: requestData)
    }
}

public enum NetworkToolValidation {
    public static func normalizedHost(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FloeError.validationFailed("host must not be empty")
        }
        guard trimmed.utf8.count <= NetworkToolLimits.maximumHostBytes else {
            throw FloeError.validationFailed("host is longer than 253 bytes")
        }
        guard !trimmed.contains("://") else {
            throw FloeError.validationFailed("host must not include a scheme")
        }
        let forbidden = CharacterSet(charactersIn: " /\\?#@")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw FloeError.validationFailed(
                "host must be a bare hostname or IP address (no scheme, space, path, query or credentials)")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw FloeError.validationFailed("host must not contain control characters")
        }
        return trimmed
    }

    public static func normalizedPort(_ port: Int) throws -> Int {
        guard (1...65_535).contains(port) else {
            throw FloeError.validationFailed("port must be 1-65535")
        }
        return port
    }

    public static func clampTimeout(_ value: Int?, defaultValue: Int) -> Int {
        let candidate = value ?? defaultValue
        return min(NetworkToolLimits.maximumTimeoutMs,
                   max(NetworkToolLimits.minimumTimeoutMs, candidate))
    }

    public static func clampPingCount(_ value: Int?) -> Int {
        let candidate = value ?? 4
        return min(NetworkToolLimits.maximumPingCount,
                   max(NetworkToolLimits.minimumPingCount, candidate))
    }

    public static func clampRedirects(_ value: Int?) -> Int {
        let candidate = value ?? NetworkToolLimits.defaultMaxRedirects
        return min(NetworkToolLimits.maximumRedirects, max(0, candidate))
    }

    public static func recordType(_ raw: String?) throws -> String {
        guard let raw, !raw.isEmpty else { return "A_AND_AAAA" }
        let upper = raw.uppercased()
        guard ["A", "AAAA", "A_AND_AAAA"].contains(upper) else {
            throw FloeError.validationFailed("recordType must be A, AAAA or A_AND_AAAA")
        }
        return upper
    }

    // MARK: - G07.2 LAN discovery

    /// A validated private IPv4 subnet plan (pure value; no probing).
    public struct PrivateSubnet: Sendable, Equatable {
        public let cidr: String
        public let networkAddress: String
        public let prefix: Int
        public let hostCount: Int
    }

    public static func serviceTypes(_ raw: [String]?) throws -> [String] {
        guard let raw else { return [] }
        guard raw.count <= NetworkToolLimits.maximumLANServiceTypes else {
            throw FloeError.validationFailed(
                "serviceTypes must contain at most 8 entries")
        }
        var seen = Set<String>()
        var normalized: [String] = []
        for value in raw {
            let type = try normalizedServiceType(value)
            guard seen.insert(type).inserted else {
                throw FloeError.validationFailed("serviceTypes must be unique")
            }
            normalized.append(type)
        }
        return normalized
    }

    /// Exact frozen syntax `^_[a-z0-9](?:[a-z0-9-]{0,13}[a-z0-9])?\._(tcp|udp)$`,
    /// normalized to lowercase. The whole type is at most 32 bytes.
    public static func normalizedServiceType(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 32 else {
            throw FloeError.validationFailed(
                "serviceTypes must be DNS-SD types such as _http._tcp")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].first == "_", parts[1].first == "_" else {
            throw FloeError.validationFailed(
                "serviceTypes must be DNS-SD types such as _http._tcp")
        }
        let label = String(parts[0].dropFirst())
        let transport = String(parts[1].dropFirst())
        guard transport == "tcp" || transport == "udp" else {
            throw FloeError.validationFailed(
                "serviceTypes transport must be _tcp or _udp")
        }
        guard (1...15).contains(label.count),
              let first = label.first, first.isASCII,
              first.isLowercase || first.isNumber,
              let last = label.last, last.isASCII,
              last.isLowercase || last.isNumber else {
            throw FloeError.validationFailed(
                "serviceTypes must be DNS-SD types such as _http._tcp")
        }
        for character in label {
            let allowed = character.isASCII
                && (character.isLowercase || character.isNumber || character == "-")
            guard allowed else {
                throw FloeError.validationFailed(
                    "serviceTypes must be DNS-SD types such as _http._tcp")
            }
        }
        return value
    }

    public static func privateSubnet(_ raw: String) throws -> PrivateSubnet {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]),
              (24...30).contains(prefix) else {
            throw FloeError.validationFailed(
                "subnetCidr must be an IPv4 CIDR with a /24-/30 prefix")
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            throw FloeError.validationFailed("subnetCidr is not an IPv4 address")
        }
        var address: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3,
                  octet.allSatisfy(\.isNumber),
                  octet.count == 1 || octet.first != "0",
                  let number = UInt32(octet), number <= 255 else {
                throw FloeError.validationFailed("subnetCidr is not an IPv4 address")
            }
            address = (address << 8) | number
        }
        let mask: UInt32 = prefix == 0 ? 0 : (0xFFFF_FFFF << (32 - UInt32(prefix)))
        let network = address & mask
        guard network == address else {
            throw FloeError.validationFailed("subnetCidr host bits must be zero")
        }
        let rendered = [
            network >> 24, (network >> 16) & 0xFF,
            (network >> 8) & 0xFF, network & 0xFF,
        ].map { String($0) }.joined(separator: ".")
        guard isPrivateIPv4(rendered) else {
            throw FloeError.validationFailed(
                "subnetCidr must be an RFC1918 private subnet")
        }
        let hostCount = (1 << (32 - prefix)) - 2
        return PrivateSubnet(cidr: "\(rendered)/\(prefix)",
                             networkAddress: rendered,
                             prefix: prefix,
                             hostCount: hostCount)
    }

    public static func lanPorts(_ raw: [Int]?) throws -> [Int] {
        guard let raw else {
            throw FloeError.validationFailed("ports are required together with subnetCidr")
        }
        guard !raw.isEmpty, raw.count <= NetworkToolLimits.maximumLANPorts else {
            throw FloeError.validationFailed("ports must contain 1-8 entries")
        }
        var seen = Set<Int>()
        for port in raw {
            guard (1...65_535).contains(port) else {
                throw FloeError.validationFailed("ports must be 1-65535")
            }
            guard seen.insert(port).inserted else {
                throw FloeError.validationFailed("ports must be unique")
            }
        }
        return raw
    }

    public static func checkLANAttemptBudget(subnet: PrivateSubnet,
                                             portCount: Int) throws {
        guard subnet.hostCount * portCount <= NetworkToolLimits.maximumLANAttempts else {
            throw FloeError.validationFailed(
                "subnetCidr x ports exceeds the 1024 TCP attempt budget")
        }
    }

    public static func lanTimeout(requested: Int?, discoveryDurationMs: Int,
                                  hasMDNS: Bool, hasTCP: Bool) throws -> Int {
        // Mirrors the frozen parser: mDNS needs the browse window + 1 s, a
        // TCP scan needs 2 s, and a combined run needs the window + 2 s.
        let required: Int
        if hasMDNS && hasTCP {
            required = discoveryDurationMs + 2_000
        } else if hasTCP {
            required = 2_000
        } else {
            required = discoveryDurationMs + 1_000
        }
        guard required <= NetworkToolLimits.maximumTimeoutMs else {
            throw FloeError.validationFailed(
                "the requested LAN discovery cannot fit inside the 30 s timeout")
        }
        let candidate = requested ?? NetworkToolLimits.defaultLANTimeoutMs
        return min(NetworkToolLimits.maximumTimeoutMs,
                   max(NetworkToolLimits.minimumTimeoutMs,
                       max(candidate, required)))
    }

    // MARK: - G07.2 speed test

    public static func normalizedSpeedURL(_ raw: String) throws -> String {
        let value = try normalizedURL(raw)
        let scheme = URLComponents(string: value)?.scheme?.lowercased()
        guard scheme == "https" else {
            throw FloeError.validationFailed(
                "speedTest endpoints must be absolute HTTPS URLs")
        }
        return value
    }

    public static func speedDirection(_ raw: String?) throws -> NetworkSpeedDirection {
        guard let raw, !raw.isEmpty else { return .download }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let direction = NetworkSpeedDirection(rawValue: normalized) else {
            throw FloeError.validationFailed(
                "direction must be download, upload or downloadAndUpload")
        }
        return direction
    }

    public static func strict(_ value: Int?, name: String, defaultValue: Int,
                              range: ClosedRange<Int>) throws -> Int {
        let candidate = value ?? defaultValue
        guard range.contains(candidate) else {
            throw FloeError.validationFailed(
                "\(name) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return candidate
    }

    public static func speedTimeout(requested: Int?, durationBudgetMs: Int,
                                    directionCount: Int) throws -> Int {
        let required = durationBudgetMs * directionCount
            + NetworkToolLimits.speedConnectionMarginMs
        guard required <= NetworkToolLimits.maximumTimeoutMs else {
            throw FloeError.validationFailed(
                "durationBudgetMs x directions exceeds the 30 s speed test deadline")
        }
        let candidate = requested ?? NetworkToolLimits.defaultSpeedTimeoutMs
        return min(NetworkToolLimits.maximumTimeoutMs,
                   max(NetworkToolLimits.minimumTimeoutMs,
                       max(candidate, required)))
    }

    public static func clamp(_ value: Int?, defaultValue: Int,
                             minimum: Int, maximum: Int) -> Int {
        min(maximum, max(minimum, value ?? defaultValue))
    }

    private static func isPrivateIPv4(_ literal: String) -> Bool {
        let parts = literal.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    /// Structural URL validation only. HTTPS is the supported first-batch
    /// transport; `http` is admitted here so the service can return its typed
    /// `unsupported`, never silently rewritten to HTTPS by the tool.
    public static func normalizedURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= NetworkToolLimits.maximumURLBytes else {
            throw FloeError.validationFailed("url must be 1-4096 bytes")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw FloeError.validationFailed("url must not contain control characters")
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw FloeError.validationFailed("url must be a valid absolute HTTP or HTTPS URL")
        }
        guard scheme == "http" || scheme == "https" else {
            throw FloeError.validationFailed("url scheme must be http or https")
        }
        guard components.user == nil, components.password == nil else {
            throw FloeError.validationFailed("url must not embed credentials")
        }
        guard components.fragment == nil else {
            throw FloeError.validationFailed("url fragments are not sent to the network")
        }
        guard let host = components.host, !host.isEmpty else {
            throw FloeError.validationFailed("url must include a host")
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw FloeError.validationFailed("url port must be 1-65535")
        }
        try validateDiagnosticTarget(host: host)
        return trimmed
    }

    /// Denies only the classes the frozen contract names as unsafe for this
    /// lane: cloud metadata endpoints, the unspecified address and multicast.
    /// Deliberate public AND private diagnostics remain allowed; the Android
    /// service re-resolves and re-checks every redirect/hop.
    public static func validateDiagnosticTarget(host: String) throws {
        var normalized = host.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while normalized.hasSuffix(".") { normalized.removeLast() }
        let metadataNames: Set<String> = [
            "metadata.google.internal", "metadata.goog", "instance-data",
            "instance-data.ec2.internal", "169.254.169.254", "fd00:ec2::254",
        ]
        if metadataNames.contains(normalized)
            || normalized.contains("169.254.169.254")
            || normalized.hasSuffix(".metadata.google.internal") {
            throw FloeError.validationFailed(
                "cloud metadata endpoints are not valid diagnostics targets")
        }
        if normalized == "0.0.0.0" || normalized == "::" {
            throw FloeError.validationFailed(
                "the unspecified address is not a valid diagnostics target")
        }
        if let first = ipv4FirstOctet(normalized), (224...239).contains(first) {
            throw FloeError.validationFailed(
                "multicast addresses are not valid diagnostics targets")
        }
        if normalized.hasPrefix("ff") && normalized.contains(":") {
            throw FloeError.validationFailed(
                "multicast addresses are not valid diagnostics targets")
        }
    }

    private static func ipv4FirstOctet(_ value: String) -> Int? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard !part.isEmpty, part.count <= 3,
                        part.allSatisfy(\.isNumber),
                        let number = Int(part) else { return false }
                  return (0...255).contains(number)
              }),
              let first = Int(parts[0]) else { return nil }
        return first
    }
}
