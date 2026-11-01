import Foundation

/// Fixed, non-configurable target for the Apple TSS reachability probe.
///
/// The pinned DDI install reaches TSS at `http://gs.apple.com/TSS/controller?action=2`
/// through its own plain-HTTP client. This probe checks only whether the
/// phone's physical network can resolve, connect and receive an HTTP header
/// from that host. It does not send a device identity, a nonce or a ticket
/// request, and it never follows a redirect.
public enum BridgeTSSProbePolicy {
    public static let host = "gs.apple.com"
    public static let port: UInt16 = 80
    public static let method = "HEAD"
    public static let path = "/TSS/controller?action=2"
    public static let requestLine = "HEAD /TSS/controller?action=2 HTTP/1.1"
    public static let totalDeadlineSeconds: TimeInterval = 10
    public static let maximumHeaderBytes = 8_192
    public static let note = "Header-only reachability check; redirects are not followed. A successful response does not prove the TSS POST, the signed ticket reply or the Rust raw-TCP client path."
}

public enum BridgeTSSReachabilityOutcome: String, Codable, Sendable {
    case httpResponse = "http-response"
    case timedOut = "timed-out"
    case cancelled
    case failed
    case notRun = "not-run"
}

public enum BridgeTSSDNSState: String, Codable, Sendable {
    case resolved
    case failed
    case unknown
}

/// One Bounded HTTP response-head observation. Only the status code and the
/// header byte count are retained; no header values and no body are kept.
public struct BridgeTSSResponseHead: Equatable, Sendable {
    public var httpStatus: Int
    public var headerBytes: Int

    public init(httpStatus: Int, headerBytes: Int) {
        self.httpStatus = httpStatus
        self.headerBytes = headerBytes
    }
}

public enum BridgeTSSResponseHeadParser {
    /// Parses only the response status line and requires the complete header
    /// terminator. Input over the 8 KiB cap is rejected before scanning. A
    /// missing terminator is not a response: the caller reports a failure.
    public static func parse(_ data: Data) -> BridgeTSSResponseHead? {
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        // The bound applies to the returned header, not to a server that also
        // placed a body in the same receive buffer. The caller still caps its
        // own accumulation when no terminator appears.
        guard terminator.upperBound <= BridgeTSSProbePolicy.maximumHeaderBytes else {
            return nil
        }
        // Use the first CRLF in the whole response: for a header-less reply the
        // status line's CRLF is also the start of the header terminator.
        guard let lineEnd = data.range(of: Data("\r\n".utf8))?.lowerBound,
              lineEnd <= terminator.lowerBound else { return nil }
        let statusLine = data.subdata(in: 0..<lineEnd)
        guard let text = String(data: statusLine, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        guard parts[0] == "HTTP/1.0" || parts[0] == "HTTP/1.1" else { return nil }
        let statusText = String(parts[1])
        guard statusText.count == 3,
              let status = Int(statusText),
              status >= 100,
              status <= 599 else { return nil }
        return BridgeTSSResponseHead(
            httpStatus: status,
            headerBytes: terminator.upperBound
        )
    }
}

public enum BridgeTSSProbeErrorCategory {
    /// Stable category names only. Raw POSIX/DNS values are not exposed in the
    /// report; a numeric POSIX category is prefixed and contains no address.
    public static func posix(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ECONNREFUSED: return "connection-refused"
        case .ETIMEDOUT: return "timed-out"
        case .ENETUNREACH: return "network-unreachable"
        case .EHOSTUNREACH: return "host-unreachable"
        case .ECONNRESET: return "connection-reset"
        case .EADDRNOTAVAIL: return "address-unavailable"
        case .ENETDOWN: return "network-down"
        case .EPIPE: return "broken-pipe"
        default: return "posix-\(code.rawValue)"
        }
    }
}

/// Bounded, non-secret reachability evidence. All fields are categories or
/// numbers; no IP address, SSID, header value or response body is present.
public struct BridgeTSSReachabilityReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var target: String
    public var method: String
    public var path: String
    public var outcome: BridgeTSSReachabilityOutcome
    public var dns: BridgeTSSDNSState
    public var tcpConnected: Bool?
    public var httpStatus: Int?
    public var durationMilliseconds: Int
    public var connectMilliseconds: Int?
    public var headersMilliseconds: Int?
    public var errorCategory: String?
    public var note: String

    public init(
        schema: Int = 1,
        target: String = "\(BridgeTSSProbePolicy.host):\(BridgeTSSProbePolicy.port)",
        method: String = BridgeTSSProbePolicy.method,
        path: String = BridgeTSSProbePolicy.path,
        outcome: BridgeTSSReachabilityOutcome,
        dns: BridgeTSSDNSState,
        tcpConnected: Bool? = nil,
        httpStatus: Int? = nil,
        durationMilliseconds: Int,
        connectMilliseconds: Int? = nil,
        headersMilliseconds: Int? = nil,
        errorCategory: String? = nil,
        note: String = BridgeTSSProbePolicy.note
    ) {
        self.schema = schema
        self.target = target
        self.method = method
        self.path = path
        self.outcome = outcome
        self.dns = dns
        self.tcpConnected = tcpConnected
        self.httpStatus = httpStatus
        self.durationMilliseconds = durationMilliseconds
        self.connectMilliseconds = connectMilliseconds
        self.headersMilliseconds = headersMilliseconds
        self.errorCategory = errorCategory
        self.note = note
    }

    /// Reachability is proven by a complete HTTP response head, not by TCP
    /// alone. Informational 1xx heads are accepted as a response but are
    /// reported with their exact status; this probe does not wait for another.
    public static func reached(
        httpStatus: Int,
        dns: BridgeTSSDNSState = .resolved,
        connectMilliseconds: Int?,
        headersMilliseconds: Int,
        durationMilliseconds: Int
    ) -> BridgeTSSReachabilityReport {
        BridgeTSSReachabilityReport(
            outcome: .httpResponse,
            dns: dns,
            tcpConnected: true,
            httpStatus: httpStatus,
            durationMilliseconds: durationMilliseconds,
            connectMilliseconds: connectMilliseconds,
            headersMilliseconds: headersMilliseconds
        )
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "target": target,
            "method": method,
            "path": path,
            "outcome": outcome.rawValue,
            "dns": dns.rawValue,
            "durationMilliseconds": durationMilliseconds,
            "note": note,
        ]
        if let tcpConnected { value["tcpConnected"] = tcpConnected }
        if let httpStatus { value["httpStatus"] = httpStatus }
        if let connectMilliseconds { value["connectMilliseconds"] = connectMilliseconds }
        if let headersMilliseconds { value["headersMilliseconds"] = headersMilliseconds }
        if let errorCategory { value["errorCategory"] = errorCategory }
        return value
    }
}

/// Exactly-once delivery of one value under callback/timeout/cancel races.
/// The winning caller is the only one allowed to resume a continuation.
public final class BridgeOneShotValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private var stored: Value?

    public init() {}

    @discardableResult
    public func deliver(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        stored = value
        return true
    }

    public var isDelivered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    public var current: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
