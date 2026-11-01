// FloeIOSAutomation — bounded wire contract for the local iOS Bridge.

import Foundation

public enum IOSBridgeProtocol {
    /// v1 is the HMAC-SHA256 encrypted-envelope pairing and /rpc contract
    /// pinned to the released Floe iOS Bridge source.
    public static let protocolVersion = 1
    public static let productName = "Floe iOS Bridge"
    public static let defaultPort: UInt16 = 8200
    public static let requestPath = "/rpc"
    public static let pairingPath = "/pair"
    public static let infoPath = "/"
    public static let schemaPath = "/schema"

    /// Hard budgets from the released host. They are refusal limits, never
    /// truncation targets.
    public static let maxRequestBodyBytes = 262_144
    public static let maxJSONResponseBytes = 16 * 1_024 * 1_024
    public static let maxStatusResponseBytes = 64 * 1_024
    public static let maxPairingResponseBytes = 16 * 1_024
    public static let timestampWindow: TimeInterval = 120
    public static let pairingTimeout: TimeInterval = 75
    public static let rpcTimeout: TimeInterval = 40
    public static let statusTimeout: TimeInterval = 4
    public static let clientNameMaximumBytes = 128
    public static let operationIDMaximumBytes = 128
    public static let snapshotMaximumClients = 100
}

public enum IOSBridgeEndpointError: Error, Equatable, Sendable {
    case invalidPort
}

/// The only endpoint the client will ever contact. The host is fixed to the
/// IPv4 loopback literal so neither a model argument nor saved configuration
/// can redirect credentials or commands to a LAN or remote address.
public struct IOSBridgeEndpoint: Sendable, Equatable, Hashable {
    public static let loopbackIPv4 = "127.0.0.1"

    public let host: String
    public let port: UInt16

    public init(port: UInt16 = IOSBridgeProtocol.defaultPort) throws {
        guard port != 0 else { throw IOSBridgeEndpointError.invalidPort }
        self.host = Self.loopbackIPv4
        self.port = port
    }

    private init(uncheckedPort: UInt16) {
        self.host = Self.loopbackIPv4
        self.port = uncheckedPort
    }

    public static let localDefault = IOSBridgeEndpoint(uncheckedPort: IOSBridgeProtocol.defaultPort)

    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        guard let url = components.url else {
            preconditionFailure("The validated loopback endpoint must form a URL.")
        }
        return url
    }

    public func url(forPath path: String) -> URL? {
        guard Self.isValidPath(path) else { return nil }
        return URL(string: path, relativeTo: baseURL)
    }

    private static func isValidPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 2_048 else { return false }
        return !path.utf8.contains(where: { $0 < 0x21 || $0 == 0x7F })
    }
}

public struct IOSBridgeHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct IOSBridgeHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }
}

public enum IOSBridgeTransportError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest(String)
    case requestTooLarge(Int)
    case responseTooLarge(Int)
    case unreachable
    case transportNotPermitted
    case timedOut
    case connectionLost
    case cancelled
    case redirectRefused
    case invalidResponse(String)

    /// True only when the request may already have reached the Bridge. This
    /// is the distinction the caller needs before deciding that a mutation
    /// has an unknown outcome instead of a definite non-delivery.
    public var requestMayHaveBeenSent: Bool {
        switch self {
        case .invalidEndpoint, .invalidRequest, .requestTooLarge, .unreachable,
             .transportNotPermitted, .redirectRefused:
            return false
        case .responseTooLarge, .timedOut, .connectionLost, .cancelled, .invalidResponse:
            return true
        }
    }
}

public protocol IOSBridgeHTTPTransport: Sendable {
    func send(
        _ request: IOSBridgeHTTPRequest,
        endpoint: IOSBridgeEndpoint,
        timeout: TimeInterval,
        cancellation: IOSAutomationCancellationToken?
    ) async throws -> IOSBridgeHTTPResponse
}
