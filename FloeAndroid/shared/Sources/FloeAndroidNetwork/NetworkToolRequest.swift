// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics — the exact request v1 built for
// `PhoneNetworkService.execute(String)` and the tool-side argument guards.
//
// Frozen input contract (platform01):
//   {version:1, operationID:UUID, method:<exact tool name>, arguments:{...}}
//   network.status{}; network.wifiScan{refresh?:bool=false};
//   network.dnsLookup{host,recordType?=A_AND_AAAA,timeoutMs?=5000};
//   network.ping{host,count?=4,timeoutMs?=5000};
//   network.tcpProbe{host,port,timeoutMs?=5000};
//   network.http{url,timeoutMs?=10000,maxRedirects?=5}.
//
// Bounds: request <= 16 KiB, observation <= 256 KiB, AP rows <= 256, ping
// count <= 10, any timeout <= 30 s. Timing/count values are CLAMPED; a host,
// port or URL that is structurally invalid is REFUSED. The service remains
// authoritative for DNS/routing/TLS/permission decisions.
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
}

public enum NetworkToolMethod: String, Sendable, CaseIterable {
    case status = "network.status"
    case wifiScan = "network.wifiScan"
    case dnsLookup = "network.dnsLookup"
    case ping = "network.ping"
    case tcpProbe = "network.tcpProbe"
    case http = "network.http"
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
