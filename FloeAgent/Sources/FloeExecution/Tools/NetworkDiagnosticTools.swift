import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeSSH
import Darwin
import Network

/// Fixed-command network diagnostics executed on a paired SSH host. These
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
              trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else {
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
        var text = "method=\(method) exitCode=\(result.exitCode) truncated=\(result.truncated)"
        if !result.stdout.isEmpty { text += "\nstdout:\n\(result.stdout)" }
        if !result.stderr.isEmpty { text += "\nstderr:\n\(result.stderr)" }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: result.exitCode)
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
    public static let toolDescription = "Run a bounded ICMP ping from a paired SSH host. Use this before VNC or other connection attempts to distinguish host reachability from service failure."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string","description":"Hostname or IP to ping"},"executionTarget":{"type":"string","enum":["device","host"],"description":"Defaults to device; host requires hostID"},"hostID":{"type":"string","description":"Optional paired SSH host UUID that runs the probe; omitted uses the default host"},"count":{"type":"integer","minimum":1,"maximum":10},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":10}},"required":["target"],"additionalProperties":false}"#
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
        guard (1...10).contains(args.count ?? 4),
              (1...10).contains(args.timeoutSeconds ?? 3) else {
            throw FloeError.validationFailed("count and timeoutSeconds must be between 1 and 10")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try NetworkDiagnosticSupport.target(args.target)
        let count = args.count ?? 4
        let timeout = args.timeoutSeconds ?? 3
        guard try !NetworkDiagnosticSupport.isDevice(args.executionTarget, hostID: args.hostID) else {
            throw FloeError.validationFailed("deviceICMPUnavailable: select executionTarget=host with hostID for real ICMP, or network.tcpProbe for device TCP reachability")
        }
        guard let service else { throw FloeError.validationFailed("hostExecutorUnavailable: configure an SSH host first") }
        let result = try await service.run(
            command: "ping -c \(count) -W \(timeout) \(target)",
            hostID: try NetworkDiagnosticSupport.hostID(args.hostID),
            timeout: TimeInterval(count * timeout + 5),
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
    public static let toolDescription = "Run a bounded route trace from a paired SSH host. Returns the real hop output from traceroute or tracepath; it never fabricates unavailable hops."
    public static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"string","description":"Hostname or IP to trace"},"executionTarget":{"type":"string","enum":["device","host"],"description":"Defaults to device; host requires hostID"},"hostID":{"type":"string","description":"Optional paired SSH host UUID that runs the trace; omitted uses the default host"},"maxHops":{"type":"integer","minimum":1,"maximum":30},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":5}},"required":["target"],"additionalProperties":false}"#
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
            throw FloeError.validationFailed("deviceTracerouteUnavailable: select executionTarget=host with hostID for a real route trace")
        }
        guard let service else { throw FloeError.validationFailed("hostExecutorUnavailable: configure an SSH host first") }
        let command = "if command -v traceroute >/dev/null 2>&1; then traceroute -m \(hops) -w \(wait) \(target); elif command -v tracepath >/dev/null 2>&1; then tracepath -m \(hops) \(target); else echo 'traceroute unavailable on probe host' >&2; exit 127; fi"
        let result = try await service.run(
            command: command,
            hostID: try NetworkDiagnosticSupport.hostID(args.hostID),
            timeout: TimeInterval(hops * wait + 10),
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
    public static let toolDescription = "Resolve a hostname on this device by default, or on an explicitly selected SSH host."
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
            let addresses = try await Task.detached { try NetworkDiagnosticSupport.dns(target) }.value
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
    public static let toolDescription = "Probe one TCP port on this device by default, or on an explicitly selected SSH host, with a bounded timeout. Useful for checking VNC, SSH, HTTP and database service reachability after ping."
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
