import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeSSH
import Darwin
import Network

/// Device diagnostics and explicitly selected fixed-command SSH probes. These
/// tools keep host IDs, timeouts and targets structured, so the model does not
/// need to construct arbitrary shell just to answer basic connectivity
/// questions.
private enum NetworkDiagnosticSupport {
    static func isDevice(_ executionTarget: String?, hostID: String?) throws -> Bool {
        guard executionTarget == nil || ["device", "host"].contains(executionTarget!) else {
            throw FloeError.validationFailed("executionTarget must be device or host")
        }
        let device = executionTarget.map { $0 == "device" } ?? (hostID == nil)
        if device, hostID != nil { throw FloeError.validationFailed("Do not combine executionTarget=device with hostID") }
        if !device, hostID == nil { throw FloeError.validationFailed("executionTarget=host requires hostID") }
        return device
    }

    static func localOutput(_ text: String) -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "executionTarget=device\n" + text,
            fullOutputSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), exitStatus: 0)
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

    static func hostID(_ value: String?) throws -> UUID? {
        guard let value else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw FloeError.validationFailed("hostID must be a UUID when provided")
        }
        return id
    }

    static func output(_ result: SSHExecResult, method: String) -> ToolExecutionOutput {
        var text = "executionTarget=host method=\(method) exitCode=\(result.exitCode) truncated=\(result.truncated)"
        if !result.stdout.isEmpty { text += "\nstdout:\n\(result.stdout)" }
        if !result.stderr.isEmpty { text += "\nstderr:\n\(result.stderr)" }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: result.exitCode)
    }
}

/// Command builders, watchdog budgets and deadline helpers for the network
/// diagnostic tools. Internal (not private) so the FloeExecution test target
/// can exercise the pure math without any network or SSH traffic.
enum NetworkDiagnosticTiming {
    /// iputils `ping -W` waits in seconds; the BSD/macOS ping waits in
    /// milliseconds. Uninspected and non-macOS hosts keep the Linux seconds
    /// semantics: that is the safe direction, because a millisecond value
    /// sent to iputils would wait thousands of seconds per reply.
    static func pingWaitValue(timeoutSeconds: Int, kind: RemoteTargetKind?) -> Int {
        kind == .macOS ? timeoutSeconds * 1000 : timeoutSeconds
    }

    static func pingCommand(target: String, count: Int, timeoutSeconds: Int, kind: RemoteTargetKind?) -> String {
        "ping -c \(count) -W \(pingWaitValue(timeoutSeconds: timeoutSeconds, kind: kind)) \(target)"
    }

    /// Covers `count` sends at the fixed 1 s interval plus one final
    /// per-reply wait and slack; the previous count*timeout+5 budget was
    /// far looser than the command's real worst case.
    static func pingWatchdogSeconds(count: Int, timeoutSeconds: Int) -> TimeInterval {
        TimeInterval(count + timeoutSeconds + 15)
    }

    /// Upper bound for a numeric traceroute with 2 probes per hop, plus
    /// slack. Shared by the SSH watchdog and the remote `timeout` wrapping
    /// the tracepath fallback so the two cannot drift apart.
    static func tracerouteBudgetSeconds(maxHops: Int, waitSeconds: Int) -> Int {
        maxHops * 2 * waitSeconds + 15
    }

    static func tracerouteCommand(target: String, maxHops: Int, waitSeconds: Int) -> String {
        // -n keeps every hop numeric: reverse-DNS lookups stall each hop for
        // seconds. -q 2 sends two probes per hop instead of the default
        // three. The tracepath fallback has no per-probe wait flag, so it is
        // wrapped in the same budget via the remote `timeout` command.
        let budget = tracerouteBudgetSeconds(maxHops: maxHops, waitSeconds: waitSeconds)
        return "if command -v traceroute >/dev/null 2>&1; then traceroute -n -q 2 -m \(maxHops) -w \(waitSeconds) \(target); elif command -v tracepath >/dev/null 2>&1; then timeout \(budget) tracepath -n -m \(maxHops) \(target); else echo 'traceroute unavailable on probe host' >&2; exit 127; fi"
    }

    /// Reads the inspection cached by `SSHCommandService.inspectTarget`.
    /// Nil when the host was never inspected — the ping dialect then
    /// defaults to Linux/iputils seconds.
    static func persistedTargetKind(hostID: UUID?, defaults: UserDefaults = .standard) -> RemoteTargetKind? {
        guard let hostID,
              let data = defaults.data(forKey: SSHCommandService.inspectionCacheKey(hostID: hostID)),
              let inspection = try? JSONDecoder().decode(RemoteTargetInspection.self, from: data) else {
            return nil
        }
        return inspection.kind
    }

    /// Races a blocking operation (getaddrinfo cannot be interrupted)
    /// against a deadline. The first finisher wins; an overrunning operation
    /// keeps running detached but its result is discarded.
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
        public var hostID: String?
        public var executionTarget: String?
        public var count: Int?
        public var timeoutSeconds: Int?
    }
    public static let name = "network.ping"
    public static let toolDescription = "Run a bounded genuine ICMP echo (ping). On this device (the default when hostID is omitted) it uses a datagram ICMP socket — no entitlement needed — sending one probe per second and reporting per-reply RTT plus min/avg/max and loss. With executionTarget=host and hostID it runs ping on that paired SSH host instead (per-reply wait is emitted in milliseconds for macOS/BSD targets and seconds for Linux). Never report a simulated ping. For device TCP service reachability use network.tcpProbe; ping is not a mandatory prerequisite for VNC."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string","description":"Hostname or IP to ping"},"executionTarget":{"type":"string","enum":["device","host"],"description":"Defaults to device when hostID is omitted; device runs a real bounded ICMP echo from this device (IPv4). Select host with hostID to ping from that paired SSH host instead."},"hostID":{"type":"string","description":"Explicit paired SSH host UUID. Supplying it selects host unless executionTarget is specified. No default host is inferred."},"count":{"type":"integer","minimum":1,"maximum":10},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":10}},"required":["target"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let service: SSHCommandService?
    /// Device ping backend; tests inject a fake so no real ICMP is needed.
    private let devicePinger: DevicePingHandler
    public init(service: SSHCommandService? = nil) {
        self.init(service: service, devicePinger: nil)
    }
    init(service: SSHCommandService?, devicePinger: DevicePingHandler?) {
        self.service = service
        self.devicePinger = devicePinger ?? DeviceICMPPing.run
    }
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        _ = try NetworkDiagnosticSupport.hostID(args.hostID)
        _ = try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID)
        guard (1...10).contains(args.count ?? 4),
              (1...10).contains(args.timeoutSeconds ?? 3) else {
            throw FloeError.validationFailed("count and timeoutSeconds must be between 1 and 10")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        let count = args.count ?? 4
        let timeout = args.timeoutSeconds ?? 3
        if try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID) {
            try context.cancellation.throwIfCancelled()
            let report = try await devicePinger(target, count, timeout, context.cancellation)
            try context.cancellation.throwIfCancelled()
            return NetworkDiagnosticSupport.localOutput(report.summaryText())
        }
        guard let service else { throw FloeError.validationFailed("hostExecutorUnavailable: configure an SSH host first") }
        let resolvedHostID = try NetworkDiagnosticSupport.hostID(args.hostID)
        let kind = NetworkDiagnosticTiming.persistedTargetKind(hostID: resolvedHostID)
        let result = try await service.run(
            command: NetworkDiagnosticTiming.pingCommand(target: target, count: count, timeoutSeconds: timeout, kind: kind),
            hostID: resolvedHostID,
            timeout: NetworkDiagnosticTiming.pingWatchdogSeconds(count: count, timeoutSeconds: timeout),
            maxOutputBytes: 32 * 1024,
            cancellation: context.cancellation
        )
        return NetworkDiagnosticSupport.output(result, method: "icmpPing")
    }
}

public struct NetworkTracerouteTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
        public var hostID: String?
        public var executionTarget: String?
        public var maxHops: Int?
        public var timeoutSeconds: Int?
    }
    public static let name = "network.traceroute"
    public static let toolDescription = "Run a bounded genuine traceroute (numeric output, 2 probes per hop) or a timeout-wrapped tracepath fallback on an explicitly selected SSH host. Device traceroute is unavailable and returns deviceTracerouteUnavailable; device ICMP ping IS available via network.ping. Never infer hops from TCP or HTTP probes."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string","description":"Hostname or IP to trace"},"executionTarget":{"type":"string","enum":["device","host"],"description":"Defaults to device when hostID is omitted; device traceroute is unavailable (use network.ping for device ICMP). Select host with hostID for a route trace."},"hostID":{"type":"string","description":"Explicit paired SSH host UUID. Supplying it selects host unless executionTarget is specified. No default host is inferred."},"maxHops":{"type":"integer","minimum":1,"maximum":30},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":5}},"required":["target"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let service: SSHCommandService?
    public init(service: SSHCommandService? = nil) { self.service = service }
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        _ = try NetworkDiagnosticSupport.hostID(args.hostID)
        _ = try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID)
        guard (1...30).contains(args.maxHops ?? 20),
              (1...5).contains(args.timeoutSeconds ?? 2) else {
            throw FloeError.validationFailed("maxHops must be 1-30 and timeoutSeconds 1-5")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        let hops = args.maxHops ?? 20
        let wait = args.timeoutSeconds ?? 2
        guard try !NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID) else {
            throw FloeError.validationFailed("deviceTracerouteUnavailable: device traceroute is unavailable; device ICMP ping works via network.ping, or select executionTarget=host with hostID for a real route trace")
        }
        guard let service else { throw FloeError.validationFailed("hostExecutorUnavailable: configure an SSH host first") }
        let result = try await service.run(
            command: NetworkDiagnosticTiming.tracerouteCommand(target: target, maxHops: hops, waitSeconds: wait),
            hostID: try NetworkDiagnosticSupport.hostID(args.hostID),
            timeout: TimeInterval(NetworkDiagnosticTiming.tracerouteBudgetSeconds(maxHops: hops, waitSeconds: wait)),
            maxOutputBytes: 64 * 1024,
            cancellation: context.cancellation
        )
        return NetworkDiagnosticSupport.output(result, method: "routeTrace")
    }
}

public struct NetworkDNSLookupTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
        public var hostID: String?
        public var executionTarget: String?
    }
    public static let name = "network.dnsLookup"
    public static let toolDescription = "Resolve a hostname on this device by default (bounded by a 10s deadline), or on an explicitly selected SSH host."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string"},"executionTarget":{"type":"string","enum":["device","host"],"description":"Defaults to device; host requires hostID"},"hostID":{"type":"string"}},"required":["target"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let service: SSHCommandService?
    public init(service: SSHCommandService? = nil) { self.service = service }
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        _ = try NetworkDiagnosticSupport.hostID(args.hostID)
        _ = try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID)
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        if try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID) {
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
        guard let service else { throw FloeError.validationFailed("hostExecutorUnavailable: configure an SSH host first") }
        let command = "if command -v getent >/dev/null 2>&1; then getent ahosts \(target); elif command -v nslookup >/dev/null 2>&1; then nslookup \(target); else host \(target); fi"
        let result = try await service.run(
            command: command,
            hostID: try NetworkDiagnosticSupport.hostID(args.hostID),
            timeout: 15,
            maxOutputBytes: 32 * 1024,
            cancellation: context.cancellation
        )
        return NetworkDiagnosticSupport.output(result, method: "dnsLookup")
    }
}

public struct NetworkTCPProbeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var target: String
        public var port: Int
        public var hostID: String?
        public var executionTarget: String?
        public var timeoutSeconds: Int?
    }
    public static let name = "network.tcpProbe"
    public static let toolDescription = "Probe one TCP port on this device by default, or on an explicitly selected SSH host, with a bounded timeout. Use directly for VNC, SSH, HTTP and database service reachability; ping is not a prerequisite. A TCP result is not ICMP reachability or a traceroute."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535},"executionTarget":{"type":"string","enum":["device","host"],"description":"Defaults to device; host requires hostID"},"hostID":{"type":"string"},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":10}},"required":["target","port"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let service: SSHCommandService?
    public init(service: SSHCommandService? = nil) { self.service = service }
    public func validate(_ args: Arguments) throws {
        _ = try NetworkDiagnosticSupport.target(args.target)
        _ = try NetworkDiagnosticSupport.hostID(args.hostID)
        _ = try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID)
        guard (1...65535).contains(args.port),
              (1...10).contains(args.timeoutSeconds ?? 3) else {
            throw FloeError.validationFailed("port must be 1-65535 and timeoutSeconds 1-10")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        let timeout = args.timeoutSeconds ?? 3
        if try NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID) {
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
        guard let service else { throw FloeError.validationFailed("hostExecutorUnavailable: configure an SSH host first") }
        let command = "if command -v nc >/dev/null 2>&1; then nc -vz -w \(timeout) \(target) \(args.port); else timeout \(timeout) sh -c 'echo >/dev/tcp/\(target)/\(args.port)'; fi"
        let result = try await service.run(
            command: command,
            hostID: try NetworkDiagnosticSupport.hostID(args.hostID),
            timeout: TimeInterval(timeout + 5),
            maxOutputBytes: 16 * 1024,
            cancellation: context.cancellation
        )
        return NetworkDiagnosticSupport.output(result, method: "tcpProbe")
    }
}
