import Foundation
import FloeCore
import FloeTools
import Darwin
import Network

/// Device-local network diagnostics. These tools never depend on an SSH host:
/// they run genuine ICMP/DNS/TCP operations from this device, keep targets
/// and timeouts structured, and never construct shell commands.
private enum NetworkDiagnosticSupport {
    static func localOutput(_ text: String) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: "executionTarget=device\n" + text,
            fullOutputSHA256: FloeDigest.sha256Hex(Data(text.utf8)),
            exitStatus: 0
        )
    }

    static func dns(_ target: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target, nil, &hints, &result) == 0, let first = result else {
            throw FloeError.validationFailed("Device DNS lookup failed")
        }
        defer { freeaddrinfo(first) }
        var addresses: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(cString: buffer))
            }
            cursor = current.pointee.ai_next
        }
        return addresses.sorted()
    }

    static func target(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253,
              trimmed.range(of: #"^[A-Za-z0-9:][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("target must be a hostname or IP address")
        }
        return trimmed
    }
}

/// Deadline helper for blocking lookups (getaddrinfo cannot be interrupted).
/// Internal so the FloeExecution test target can exercise the pure race.
enum NetworkDiagnosticTiming {
    static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        timeoutMessage: String,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let arbiter = DeadlineArbiter<T>()
        return try await withCheckedThrowingContinuation { continuation in
            arbiter.arm(continuation)
            Task.detached {
                arbiter.resolve(Result { try operation() })
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                arbiter.resolve(.failure(FloeError.validationFailed(timeoutMessage)))
            }
        }
    }
}

/// One-shot race arbiter for `withDeadline`: only the first completion
/// resumes the continuation.
private final class DeadlineArbiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved = false

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved, let continuation else { return }
        resolved = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

public struct NetworkPingTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
        public var count: Int?
        public var timeoutSeconds: Int?
    }
    public static let name = "network.ping"
    public static let toolDescription = "Run a bounded genuine ICMP echo (ping) from this device using a datagram ICMP socket (no entitlement needed): one probe per second, per-reply RTT plus min/avg/max and loss. IPv4 only. Never report a simulated ping. For TCP service reachability use network.tcpProbe; ping is not a mandatory prerequisite for VNC. This tool never runs on a remote host."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string","description":"Hostname or IPv4 address to ping"},"count":{"type":"integer","minimum":1,"maximum":10},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":10}},"required":["target"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let devicePinger: DevicePingHandler
    public init() {
        self.init(devicePinger: nil)
    }
    init(devicePinger: DevicePingHandler?) {
        self.devicePinger = devicePinger ?? DeviceICMPPing.run
    }
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        guard (1...10).contains(args.count ?? 4),
              (1...10).contains(args.timeoutSeconds ?? 3) else {
            throw FloeError.validationFailed("count and timeoutSeconds must be between 1 and 10")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        let count = args.count ?? 4
        let timeout = args.timeoutSeconds ?? 3
        try context.cancellation.throwIfCancelled()
        let report = try await devicePinger(target, count, timeout, context.cancellation)
        try context.cancellation.throwIfCancelled()
        return NetworkDiagnosticSupport.localOutput(report.summaryText())
    }
}

public struct NetworkTracerouteTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
        public var maxHops: Int?
        public var timeoutSeconds: Int?
    }
    public static let name = "network.traceroute"
    public static let toolDescription = "Run a bounded genuine ICMP traceroute from this device (IPv4): increasing IP TTL with two probes per hop, numeric per-hop addresses and RTTs, timeout hops reported as such. Uses the same unprivileged datagram ICMP socket as network.ping; no entitlement and no remote host. Never infer hops from TCP or HTTP probes."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string","description":"Hostname or IPv4 address to trace"},"maxHops":{"type":"integer","minimum":1,"maximum":30},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":5,"description":"Per-probe wait in seconds"}},"required":["target"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let deviceTracer: DeviceTracerouteHandler
    public init() {
        self.init(deviceTracer: nil)
    }
    init(deviceTracer: DeviceTracerouteHandler?) {
        self.deviceTracer = deviceTracer ?? DeviceICMPTraceroute.run
    }
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        guard (1...30).contains(args.maxHops ?? 20),
              (1...5).contains(args.timeoutSeconds ?? 2) else {
            throw FloeError.validationFailed("maxHops must be 1-30 and timeoutSeconds 1-5")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        try context.cancellation.throwIfCancelled()
        let report = try await deviceTracer(
            target,
            args.maxHops ?? 20,
            args.timeoutSeconds ?? 2,
            context.cancellation
        )
        try context.cancellation.throwIfCancelled()
        return NetworkDiagnosticSupport.localOutput(report.summaryText())
    }
}

public struct NetworkDNSLookupTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
    }
    public static let name = "network.dnsLookup"
    public static let toolDescription = "Resolve a hostname from this device (A and AAAA records, bounded by a 10s deadline). This tool never runs on a remote host."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string"}},"required":["target"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    public init() {}
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        try context.cancellation.throwIfCancelled()
        // getaddrinfo can block for the full resolver timeout; race it
        // against a 10 s deadline so a stuck resolver fails cleanly.
        let addresses = try await NetworkDiagnosticTiming.withDeadline(
            seconds: 10,
            timeoutMessage: "device dnsLookup timed out after 10s"
        ) {
            try NetworkDiagnosticSupport.dns(target)
        }
        try context.cancellation.throwIfCancelled()
        return NetworkDiagnosticSupport.localOutput("method=dnsLookup addresses=" + addresses.joined(separator: ", "))
    }
}

public struct NetworkTCPProbeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
        public var port: Int
        public var timeoutSeconds: Int?
    }
    public static let name = "network.tcpProbe"
    public static let toolDescription = "Probe one TCP port from this device with a bounded timeout. Use directly for VNC, SSH, HTTP and database service reachability; ping is not a prerequisite. A TCP result is not ICMP reachability or a traceroute. This tool never runs on a remote host."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":10}},"required":["target","port"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    public init() {}
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        guard (1...65535).contains(args.port),
              (1...10).contains(args.timeoutSeconds ?? 3) else {
            throw FloeError.validationFailed("port must be 1-65535 and timeoutSeconds 1-10")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        let timeout = args.timeoutSeconds ?? 3
        try context.cancellation.throwIfCancelled()
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: args.port) ?? 0), args.port > 0 else {
            throw FloeError.validationFailed("invalid TCP port")
        }
        let connection = RawTCPConnection(host: NWEndpoint.Host(target), port: port, telnet: false)
        defer { connection.close() }
        try await withTaskCancellationHandler {
            try await connection.connect(timeout: TimeInterval(timeout))
        } onCancel: { connection.close() }
        try context.cancellation.throwIfCancelled()
        return NetworkDiagnosticSupport.localOutput("method=tcpProbe connected=true target=\(target) port=\(args.port)")
    }
}
